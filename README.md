# Multi-Cluster Inference Gateway + Flow Control + Kueue Preemption Demo

Live demo of GKE's Multi-Cluster Inference Gateway with KV-cache-aware routing, EPP flow control for request-level prioritization, and Kueue-based GPU preemption, running on NVIDIA RTX PRO 6000 Blackwell GPUs.

## What This Demo Shows

Two GKE worker clusters (`us-east1`, `us-west3`) each run vLLM inference pods serving `meta-llama/Llama-3.1-8B-Instruct` with LoRA adapters. A management cluster ties them together with a cross-region gateway, MultiKueue federation, and an Endpoint Picker (EPP v1.4.0) with flow control for intelligent, priority-aware request routing.

The demo has three acts:

1. **MultiKueue Training Distribution** — Submit training jobs to the management cluster. MultiKueue evaluates GPU capacity across both workers and dispatches each job to a cluster with room.

2. **Inference Preemption Under Load** — Blast one cluster with inference traffic. Its KV cache fills up, the HPA scales out new inference pods, and Kueue preempts lower-priority training jobs to free GPUs. The evicted training job gets rescheduled by MultiKueue to the other cluster that still has capacity.

3. **Flow Control & Request Prioritization** — Under heavy load, the EPP's saturation detector engages and holds requests in memory. Production requests (`food-review-prod`, priority 100) dispatch ahead of batch requests (`food-review-batch`, priority -10). Fair queuing ensures no single tenant monopolizes capacity within a priority band.

### Architecture

```
                         ┌──────────────────┐
                         │  Management GKE  │
                         │                  │
                         │  Gateway + Route │
                         │  MultiKueue      │
                         │  GCPBackendPolicy│
                         └────────┬─────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    ▼                           ▼
          ┌─────────────────┐           ┌─────────────────┐
          │  us-east1       │           │  us-west3       │
          │  (8 GPU)        │           │  (8 GPU)        │
          │  vLLM pods (2-6)│           │  vLLM pods (0-6)│
          │  EPP v1.4.0     │           │  EPP v1.4.0     │
          │  Flow Control   │           │  Flow Control   │
          │  InferencePool  │           │  InferencePool  │
          │  Kueue queues   │           │  Kueue queues   │
          │  HPA            │           │  HPA (min=0)    │
          └─────────────────┘           └─────────────────┘
```

### Routing (Three Tiers)

- **Tier 1 — GCLB**: Picks which *cluster* gets the request based on geographic proximity and custom KV-cache metrics (60% threshold).
- **Tier 2 — EPP Flow Control**: When the pool is saturated (avg queue depth > 100 or KV cache > 90%), the EPP queues requests in memory and dispatches by priority. Production requests (priority 100) go before batch requests (priority -10). Fairness is enforced per-tenant within each priority band.
- **Tier 3 — EPP Scoring**: Picks which *pod* gets the request based on KV-cache utilization, prefix cache affinity, and queue depth.

Clients control flow control behavior with two HTTP headers:
- `x-gateway-inference-objective: food-review-prod` — selects the InferenceObjective (and thus priority)
- `x-gateway-inference-fairness-id: tenant-abc` — identifies the tenant for fair queuing

### Priority Model

**Workload scheduling (Kueue):**

| Workload | Priority Class | Priority | Preemptible |
|---|---|---|---|
| Critical training | `training-critical` | 2000 | No |
| Inference pods | `inference-high` | 1000 | Only by critical training |
| Training jobs | `training-low` | 100 | Yes |

**Request scheduling (EPP flow control):**

| InferenceObjective | Priority | Behavior under saturation |
|---|---|---|
| `food-review-prod` | 100 | Dispatched first |
| *(no header)* | 0 | Default, dispatched after prod |
| `food-review-batch` | -10 | Queued behind all others |

When GPUs are needed for inference scale-out, Kueue evicts training jobs first.

## Prerequisites

- `kubectl` with contexts configured: `mgmt`, `worker-east1`, `worker-west3`
- Python 3.8+ with `rich` installed (`pip install rich`)
- GKE clusters with manifests already applied (see [Infrastructure Setup](#infrastructure-setup))

## Running the Demo

The demo is a two-step process: first set up training jobs, then run the load test.

### Step 1: Reset the Environment

Always start clean. The `--target` flag controls which cluster the load test will saturate (and therefore which cluster gets more HPA headroom).

```bash
./demo-reset.sh --target west3
```

This:
- Kills any running load generator pods
- Scales inference back to 4 replicas per cluster
- Clears all training jobs
- Restores ClusterQueue GPU quotas
- Sets HPA limits (target cluster max=6, other max=4)

Options:
```bash
./demo-reset.sh --target east1              # Reset everything, target east1
./demo-reset.sh --target west3              # Reset everything, target west3
./demo-reset.sh --multikueue --target west3 # Reset only training jobs
./demo-reset.sh --loadtest --target west3   # Reset only load test state
```

### Step 2: Submit Training Jobs (MultiKueue Demo)

```bash
./demo-multikueue.sh --target west3
```

This is an interactive, narrated walkthrough that:

1. Shows the current GPU allocation across both clusters (4 inference pods each = 4 GPUs used, 4 free)
2. Submits `training-job-1` (2 GPUs) — MultiKueue dispatches to the target cluster
3. Submits `training-job-2` (2 GPUs) — MultiKueue dispatches to the target cluster (now full: 4 inf + 4 train = 8/8)
4. Submits `training-job-3` (2 GPUs) — Target is full, so MultiKueue dispatches to the other cluster
5. Shows final state: target has 0 free GPUs, other has 2 free GPUs (room for rescheduled jobs later)

The script prints the suggested load test command at the end.

Add `--auto` for an unattended version with timed pauses (good for recordings):
```bash
./demo-multikueue.sh --target west3 --auto
```

### Step 3: Run the Load Test + Dashboard

```bash
python3 load_test.py --target-cluster west3 --concurrency 300
```

This launches load generator pods inside the target cluster and opens a live Rich dashboard showing:

- **Cluster panels** — Per-pod KV cache utilization bars, running/waiting request counts, fill rate, sparkline history
- **Routing panel** — Which cluster is the load target vs. spillover destination, threshold status
- **EPP Flow Control panel** — Per-cluster EPP queue depth bars, saturation status, active InferenceObjective and fairness IDs
- **Kueue panel** — HPA replica counts and scaling metrics, workload table with cluster/type/status, training pod counts, and a live event log showing preemptions and rescheduling
- **Stats panel** — Load generator target, concurrency, success/error counts, RPS

#### What You'll See

As load ramps up on the target cluster:

1. KV cache fills toward the 60% threshold
2. HPA detects high utilization and requests more inference replicas
3. No free GPUs on the target cluster — Kueue preempts a `training-low` job to free a GPU
4. New inference pod starts on the freed GPU
5. The evicted training job gets rescheduled by MultiKueue to the other cluster (which has 2 free GPUs)
6. Events panel shows: `PREEMPTED: training-job-2-xxxxx evicted on west3` followed by `RESCHEDULED: training-job-2-xxxxx → east1`

### Dashboard Modes

The dashboard can run independently of the load test:

```bash
# Dashboard only — monitor clusters without generating any load
python3 load_test.py --mode dashboard --target-cluster west3

# Load only — generate load with periodic text stats (no Rich UI)
python3 load_test.py --mode load --target-cluster west3 --concurrency 300

# Both (default) — full experience
python3 load_test.py --mode both --target-cluster west3 --concurrency 300
```

Dashboard-only mode is useful when you want to show the live monitoring UI while triggering load from a separate terminal or process.

### All load_test.py Options

| Flag | Default | Description |
|---|---|---|
| `--mode` | `both` | `dashboard`, `load`, or `both` |
| `--target-cluster` | `east1` | Which cluster to target (`east1` or `west3`). The other becomes the spillover destination. |
| `--vip` | auto-discovered | Load balancer VIP address |
| `--concurrency` | `300` | Number of concurrent request workers |
| `--max-tokens` | `2048` | Max tokens per completion (higher = longer in-flight = more KV blocks held) |
| `--objective` | `food-review-prod` | InferenceObjective name sent via `x-gateway-inference-objective` header. Set to `food-review-batch` for low-priority load. |
| `--load-pods` | `4` | Number of load generator pods to spread concurrency across |
| `--direct-ip` | | Target a specific IP:port directly, bypassing the LB |

## Infrastructure Setup

The infrastructure spans three GKE clusters in project `kubecon-fleets-demo-1`.

### Clusters

| Cluster | Role | Region | kubectl context |
|---|---|---|---|
| Management | Gateway, HTTPRoute, MultiKueue control plane | — | `mgmt` |
| ai-worker-us-east1 | Worker: inference + training | us-east1 | `worker-east1` |
| ai-worker-us-west3 | Worker: inference + training | us-west3 | `worker-west3` |

### Manifests

Apply in order. Worker manifests go to both `worker-east1` and `worker-west3` contexts.

**Workers** (`workers/`):

| File | What it creates |
|---|---|
| `namespace.yaml` | `inference-server` namespace |
| `secret.yaml` | HuggingFace token for model downloads |
| `gpu-deployment.yaml` | vLLM Deployment + LoRA syncer sidecar + ConfigMap + Service |
| `inferencepool.yaml` | InferencePool (`vllm-llama3-8b-instruct`) with export annotation |
| `endpointpicker.yaml` | EPP v1.4.0 deployment with flow control, saturation detector, and scoring plugins |
| `autoscalingmetric.yaml` | Exports `kv-cache` metric from vLLM pods to GCP |
| `inference-objective.yaml` | Two InferenceObjectives: `food-review-prod` (priority 100) and `food-review-batch` (priority -10) |
| `validatingadmissionpolicy.yaml` | Admission policy for the inference namespace |

**Management** (`mgmt/`):

| File | What it creates |
|---|---|
| `namespace.yaml` | `gateway-system` and `inference-server` namespaces |
| `gateway.yaml` | Cross-region internal gateway |
| `httproute.yaml` | Routes to `GCPInferencePoolImport` (auto-created from worker exports) |
| `backend-policy.yaml` | `CUSTOM_METRICS` balancing with 60% KV-cache threshold |
| `healthcheck.yaml` | Health check policy for the backend service |

**Kueue** (`kueue/`):

| File | What it creates |
|---|---|
| `priority-classes.yaml` | `inference-high` (1000), `training-low` (100), `training-critical` (2000) |
| `resource-flavor.yaml` | `rtx-pro-6000` flavor |
| `cluster-queue-worker.yaml` | `gpu-cluster-queue` with preemption policy (workers) |
| `cluster-queue-mgmt.yaml` | ClusterQueue on management cluster |
| `local-queues.yaml` | `inference-queue` and `training-queue` |
| `namespace-training.yaml` | `training-jobs` namespace |
| `admission-check.yaml` | MultiKueue admission check |
| `multikueue-config.yaml` | MultiKueue configuration |
| `multikueue-cluster-*.yaml` | MultiKueueCluster references for each worker |
| `hpa-inference.yaml` | HPA for east1 vLLM deployment (scales on KV-cache utilization, min=2) |
| `hpa-inference-west3.yaml` | HPA for west3 with scale-to-zero (min=0, scales on EPP flow control queue depth) |

### Building the vLLM Image

The Dockerfile layers Blackwell-optimized settings on top of `vllm/vllm-openai`:

```bash
docker build \
  -t us-east1-docker.pkg.dev/kubecon-fleets-demo-1/vllm-blackwell/vllm-blackwell:latest .

docker push us-east1-docker.pkg.dev/kubecon-fleets-demo-1/vllm-blackwell/vllm-blackwell:latest
```

### Connecting to Clusters

```bash
gcloud container clusters get-credentials ai-worker-us-east1 \
  --region us-east1 --project kubecon-fleets-demo-1

gcloud container clusters get-credentials ai-worker-us-west3 \
  --region us-west3 --project kubecon-fleets-demo-1
```

## Troubleshooting

### KV cache not filling
- Check pod logs: `kubectl logs -n inference-server -l app=vllm-llama3-8b-instruct -f --context worker-east1`
- Verify model is loaded: `kubectl exec -n inference-server <pod> --context worker-east1 -- curl -s localhost:8000/v1/models`
- Ensure load pod is running: `kubectl get pod kv-load-gen -n inference-server --context worker-east1`

### Training jobs stuck in Pending
- Check Kueue workload status: `kubectl get workloads -A --context worker-east1`
- Verify ClusterQueue has quota: `kubectl describe clusterqueue gpu-cluster-queue --context worker-east1`
- Check MultiKueue connectivity: `kubectl get multikueuecluster -n kueue-system --context mgmt`

### HPA not scaling
- Verify HPA can see metrics: `kubectl get hpa -n inference-server --context worker-east1`
- Check HPA events: `kubectl describe hpa vllm-inference-hpa -n inference-server --context worker-east1`
- Ensure HPA max replicas allows scaling: the reset script sets target cluster max=6, other max=4

### Preempted job not rescheduling
- Check the workload on the management cluster: `kubectl get workloads -n training-jobs --context mgmt`
- Verify the other cluster has free GPUs and ClusterQueue quota is not zero
- MultiKueue rescheduling can take 30-60 seconds

### Dashboard shows stale data
- Metrics are scraped every 2 seconds via `kubectl exec` into each pod
- Kueue state is polled every 3 seconds
- If pods are restarting, the dashboard may show brief scrape errors before they recover
