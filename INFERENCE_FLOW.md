# Life of an Inference Request

This document traces a single inference request from the moment it leaves the
client to the moment the first token is generated on a Blackwell GPU, showing
every routing decision, queue, and handoff along the way.

---

## The Setup

Three GKE clusters form the platform:

| Cluster | Role | GPU Capacity |
|---------|------|--------------|
| **mgmt** | Hosts the cross-region Gateway. No GPUs. | -- |
| **ai-worker-us-east1** | Primary inference region | 8x RTX PRO 6000 |
| **ai-worker-us-west3** | Spillover / training region | 8x RTX PRO 6000 |

Each worker cluster runs:
- 2-6 vLLM pods (Llama-3.1-8B-Instruct on Blackwell sm_120)
- 1 Endpoint Picker (EPP) pod with flow control enabled
- Kueue managing GPU quota across inference and training workloads

---

## The Request

A client sends a completion request through the regional VIP:

```
POST http://10.142.0.74/v1/completions
Headers:
  Content-Type: application/json
  x-gateway-inference-objective: food-review-prod
  x-gateway-inference-fairness-id: tenant-abc
Body:
  {"model": "food-review-1", "prompt": "Review this dish: ...", "max_tokens": 512}
```

Two headers drive flow control behavior:
- **`x-gateway-inference-objective: food-review-prod`** tells the EPP which
  InferenceObjective to look up. `food-review-prod` has priority 100;
  `food-review-batch` has priority -10. Requests without this header default to
  priority 0.
- **`x-gateway-inference-fairness-id: tenant-abc`** identifies this tenant for
  fair queuing. Under contention, the EPP distributes capacity equitably among
  tenants within the same priority band.

---

## Tier 1 -- Cluster Selection (GCLB)

The VIP (`10.142.0.74`) is owned by a cross-region internal Application Load
Balancer on the mgmt cluster, configured as:

```
Gateway: cross-region-gateway
  Class: gke-l7-cross-regional-internal-managed-mc
  Listener: HTTP / port 80
  Addresses: ephemeral-ipv4 in us-east1 and us-west3
```

**HTTPRoute** `vllm-llama3-8b-instruct-default` matches all paths and forwards
to a `GCPInferencePoolImport` backend. This is a multi-cluster construct -- the
same InferencePool is exported (`networking.gke.io/export: "True"`) from both
worker clusters, and the mgmt cluster imports them as a unified backend.

### The routing decision

A `GCPBackendPolicy` controls how GCLB distributes traffic between the two
worker clusters:

```yaml
balancingMode: CUSTOM_METRICS
trafficDuration: LONG
customMetrics:
  - name: gke.named_metrics.kv-cache
    maxUtilizationPercent: 60
```

Each vLLM pod exports its KV-cache utilization (`vllm:kv_cache_usage_perc`) via
an `AutoscalingMetric` resource. These per-pod metrics flow through the GKE
metrics pipeline:

```
vLLM /metrics (port 8000)
  --> AutoscalingMetric scrapes every 5s
  --> gke-metrics-agent exports to Cloud Monitoring
  --> GCLB reads per-backend-endpoint custom metric
```

GCLB evaluates the metric across all backends in each cluster:

- **east1 avg KV < 60%**: All traffic routes to east1 (geographic affinity to
  the VIP).
- **east1 avg KV >= 60%**: GCLB begins shifting new connections to west3. The
  shift is proportional -- it doesn't flip 100% at once; it ramps based on
  relative utilization.

In our request's case, east1 is at 45% KV utilization, so **GCLB routes the
request to the east1 worker cluster**.

The health check (`/health` on port 8000) ensures only pods that have finished
model loading are considered available. The `trafficDuration: LONG` setting tells
GCLB to use connection-aware balancing -- it accounts for the fact that inference
requests hold connections open for seconds, not milliseconds.

---

## Tier 2 -- Pod Selection (Endpoint Picker)

The request arrives at the east1 cluster and hits Envoy, which is configured
with an ext_proc filter pointing at the EPP (gRPC on port 9002). The EPP
runs as a single-replica Deployment with `Recreate` strategy to maintain
prefix-cache state consistency.

The EPP processes the request in two phases: **flow control**, then **scoring**.

### Phase 1: Flow Control

The EPP extracts the flow control headers:

1. **Objective lookup**: `x-gateway-inference-objective: food-review-prod`
   matches the InferenceObjective `food-review-prod` by `metadata.name`.
   Its `spec.priority: 100` is assigned to this request.

2. **Flow key construction**: The request is filed under `FlowKey{priority: 100,
   fairness_id: "tenant-abc"}`.

3. **Saturation check**: The EPP's saturation detector evaluates pool health:
   - Is any pod's local queue depth > 2? (`queueDepthThreshold: 2`)
   - Is any pod's KV-cache utilization > 85%? (`kvCacheUtilThreshold: 0.85`)

   If **not saturated** (our case at 45% KV): the request is dispatched
   immediately. The flow controller records the request in metrics
   (`inference_extension_flow_control_queue_size`) and passes it to scoring.

   If **saturated**: the request is held in the EPP's in-memory queue. The
   goroutine blocks. A background dispatch loop continuously evaluates queues:
   - Higher-priority requests (priority 100) always dispatch before lower
     priority (priority -10 batch traffic).
   - Within the same priority, fairness policy distributes capacity equitably
     among `fairness_id` values -- `tenant-abc` won't starve `tenant-xyz`.
   - Requests exceeding `defaultRequestTTL: 30s` in the queue are shed.
   - Total queued payload is bounded to `maxBytes: 1GB`.

   This is the key shift from v1.1.0: previously, all requests were forwarded
   immediately to model servers, which would queue them internally with no
   priority awareness. Now the EPP holds the backpressure centrally, protecting
   TPOT (time-per-output-token) at the cost of TTFT (time-to-first-token).

### Phase 2: Endpoint Scoring

Once the flow controller releases the request for dispatch, three scoring
plugins evaluate every healthy pod in the InferencePool:

| Plugin | What it scores | Why it matters |
|--------|---------------|----------------|
| **queue-scorer** | Fewest requests waiting in the pod's local queue | Avoids piling onto an already-busy pod |
| **kv-cache-utilization-scorer** | Lowest KV-cache memory usage | Picks the pod with the most room for new KV blocks |
| **prefix-cache-scorer** | Highest prefix-cache hit ratio for this prompt | Reuses cached KV blocks from similar prior prompts, skipping prefill compute |

The scheduling profile runs all three plugins and combines scores. The
`max-score-picker` selects the pod with the highest composite score.

In our example, the EPP selects `vllm-llama3-8b-instruct-857c55f7ff-czjcl` --
it has 38% KV utilization (vs. 52% on the other pod), zero queued requests, and
a partial prefix-cache match from a similar prompt seen earlier.

The EPP writes the selected pod's address into the ext_proc response headers.
Envoy proxies the request to that specific pod on port 8000.

---

## Model Server -- vLLM on Blackwell

The request arrives at the vLLM OpenAI-compatible API server. The model is
loaded from GCS (`gs://kubecon-fleets-demo-1-model-weights/...`) using the
`runai_streamer` format for fast weight loading.

### LoRA Resolution

The request specifies `"model": "food-review-1"`. This isn't the base model
name -- it's a LoRA adapter alias.

The `lora-adapter-syncer` sidecar (running as a restartable init container)
watches the ConfigMap `vllm-llama3-8b-instruct-adapters`:

```yaml
vLLMLoRAConfig:
  defaultBaseModel: meta-llama/Llama-3.1-8B-Instruct
  ensureExist:
    models:
    - id: food-review-1
      source: Kawon/llama3.1-food-finetune_v14_r8
```

The syncer has already downloaded the adapter weights from HuggingFace to the
shared `/data` volume and registered it with vLLM via the runtime LoRA API
(`VLLM_ALLOW_RUNTIME_LORA_UPDATING=true`). vLLM resolves `food-review-1` to the
base model + LoRA adapter weights.

### KV-Cache Allocation and Inference

vLLM's v1 engine (`VLLM_USE_V1=1`) with FlashInfer attention backend
(`VLLM_ATTENTION_BACKEND=FLASHINFER`) processes the request:

1. **Prefix cache check**: The radix-trie prefix cache looks for matching KV
   blocks from prior prompts. Partial matches skip redundant prefill compute.

2. **KV block allocation**: vLLM's paged attention allocator reserves KV-cache
   blocks in GPU VRAM. With `expandable_segments:True`, PyTorch's CUDA allocator
   minimizes fragmentation across the 48GB VRAM.

3. **Prefill**: The prompt tokens are processed through the transformer layers
   in a single forward pass, using FlashInfer v2 tiling kernels optimized for
   Blackwell's sm_120 architecture.

4. **Decode**: Tokens are generated autoregressively. vLLM's continuous batching
   scheduler interleaves this request's decode steps with other in-flight
   requests, maximizing GPU utilization. Up to 1024 sequences can be batched
   simultaneously (`--max-num-seq 1024`).

5. **Response**: The generated tokens are streamed back (or returned as a
   complete response if `stream: false`) through Envoy, GCLB, and back to the
   client.

---

## The Metrics Feedback Loop

While the request is in flight, metrics flow back to inform future routing:

```
vLLM pod
  |-- vllm:kv_cache_usage_perc    --> AutoscalingMetric --> GCLB (Tier 1 routing)
  |-- vllm:num_requests_running   --> EPP scrapes (Tier 2 scoring)
  |-- vllm:num_requests_waiting   --> EPP scrapes (Tier 2 scoring)
  '-- vllm:kv_cache_usage_perc    --> EPP scrapes (Tier 2 scoring + saturation)

EPP pod
  |-- flow_control_queue_size     --> PodMonitoring --> HPA (scale-to-zero on west3)
  '-- flow_control_queue_duration --> observability

HPA
  |-- vllm:kv_cache_usage_perc target 45%  --> scales vLLM pods 2-6
  '-- flow_control_queue_size > 0          --> wakes west3 from zero (if configured)
```

When vLLM pods scale up, Kueue manages the GPU quota. If inference needs more
GPUs than are free, Kueue preempts lower-priority training workloads
(`training-low`, priority 100) to make room for inference pods
(`inference-high`, priority 1000). The custom MultiKueue dispatcher scores
clusters by eviction cost to pick the least-disruptive placement.

---

## What Happens Under Load

As request volume increases, the system responds at each layer:

| KV Cache % | What Happens |
|-----------|--------------|
| **0-45%** | All traffic to east1. EPP dispatches immediately. HPA holds at min replicas. |
| **45-60%** | HPA scales east1 pods (2 -> 4 -> 6). Kueue may preempt training jobs for GPU headroom. EPP still dispatching immediately. |
| **60-85%** | GCLB begins shifting traffic to west3. EPP still dispatching immediately on both clusters. |
| **>85%** | EPP saturation detector trips. Flow control engages: prod requests (priority 100) dispatch first; batch requests (priority -10) queue. TPOT is protected at the cost of increased TTFT. |

If west3 is configured with scale-to-zero (`minReplicas: 0`), the first
spillover request hits an EPP with no backends. The EPP holds the HTTP
connection in memory, the HPA detects `flow_control_queue_size > 0` and scales
from 0 -> 1, and the request is dispatched to the new pod once it passes its
startup probe -- all without dropping the client connection.
