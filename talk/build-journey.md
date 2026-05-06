# A Global Multi-Cluster Compute Pool for AI on GKE

*What you can build on GKE today: a single internal IP fronting a priority-
aware, bin-packed GPU fleet that spans regions.*

Each section below pairs slide bullets with speaker notes.

---

## 1. Title

**"One IP. Many Regions. Every GPU Earning Its Keep."**
*Building a global compute pool for AI on GKE.*

> I'm a PM on GKE. Today I want to show you a pattern we've been building and
> validating with customers: treating your GPU fleet — across regions, across
> clusters, across workload types — as a single pool of capacity. One
> endpoint for your clients. Priority and fairness baked in. Serving and
> training sharing GPUs without fighting each other. I'll walk through the
> components that make it work, what we've shipped, and what's next.

---

## 2. The problem every AI platform team has

- GPUs are expensive and scarce — you buy regional capacity, but demand is
  global and bursty
- You want to run **serving** and **training** on the same fleet, so GPUs
  aren't idle — but these workloads have opposite scheduling needs
- You want one endpoint your application teams can call, without them knowing
  or caring which region or cluster has capacity right now
- You want **priority**: production inference shouldn't wait behind a batch
  training job; critical training shouldn't lose hours to an inference spike

This is a fleet-level problem, not a cluster-level problem. Cluster-level
primitives don't compose into a solution on their own.

> Most customers we talk to have two or three regional clusters, each with
> GPUs, each running some mix of workloads, and they've built custom glue —
> CI/CD pipelines, human-in-the-loop scheduling, Slack bots — to route work
> across them. It works, but it's fragile and it leaves a lot of utilization
> on the floor. We wanted to replace that glue with platform primitives.

---

## 3. What we built

A reference architecture on GKE that turns your multi-region GPU fleet into a
single compute pool. From the outside:

- **One internal IP.** Clients call one VIP. Traffic lands in the closest
  healthy region with capacity.
- **One quota model.** Training jobs are submitted to one queue; they land
  wherever they fit best.
- **One priority model.** Request priority at L7, workload priority at the
  scheduler, consistent across clusters.

From the inside, it's GKE primitives composed in a specific way. Seven
components do the heavy lifting. I'll go through each.

---

## 4. The picture

```
                    ┌──────────────────────────┐
                    │  Management cluster      │
                    │                          │
                    │  Multi-Cluster Gateway   │◄── one internal IP
                    │  MultiKueue control plane│◄── one queue
                    │  Fleet + ClusterProfiles │◄── one view of capacity
                    └────────────┬─────────────┘
                                 │
                ┌────────────────┴────────────────┐
                ▼                                 ▼
      ┌───────────────────┐             ┌───────────────────┐
      │  us-east1         │             │  us-west3         │
      │  • vLLM + EPP     │             │  • vLLM + EPP     │
      │  • Kueue + HPA    │             │  • Kueue + HPA=0  │
      │  • Training jobs  │             │  • Training jobs  │
      │  • 8 GPUs         │             │  • 8 GPUs         │
      └───────────────────┘             └───────────────────┘
```

Two worker clusters in two regions, one management cluster tying them
together. Serving and training run side-by-side in each worker. The
management cluster has no GPUs — it's pure control plane.

> The shape generalizes. Swap regions for zones if you prefer AZ-resilient
> but regional. Add a third region. Add a cluster with a different GPU SKU.
> The pattern doesn't change — you add a ClusterProfile entry and the rest
> of the system sees it.

---

## 5. Foundation: GKE Fleets and OSS ClusterProfiles

**Fleets** give you a logical grouping of clusters with shared identity,
policy, and observability. Every cluster in the demo is enrolled in a fleet
— that's what makes cross-cluster constructs like the MCG and MultiKueue
possible.

**ClusterProfiles** (the OSS `multicluster.x-k8s.io` CRD) are how workloads
and controllers discover "what clusters exist, and what are they for?"

```yaml
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ClusterProfile
metadata:
  name: worker-west3
spec:
  clusterManager:
    name: gke-fleet
  displayName: "ai-worker-us-west3"
```

- Every worker cluster publishes a ClusterProfile to the management cluster
- Our MultiKueue dispatcher reads ClusterProfiles to enumerate candidate
  placements — no hardcoded cluster lists
- When you add a new region, you add a ClusterProfile and the system picks
  it up automatically

> This is one of the quieter but most important pieces of the stack. Fleets
> are the GKE-managed construct that gives these clusters a shared control
> plane identity. ClusterProfiles are the open standard (via the SIG
> Multicluster group) that lets any controller — not just ours — reason
> about the fleet's membership. Together they mean the system we're
> showing isn't GKE-specific in shape, even though we're using GKE-specific
> wiring underneath.

---

## 6. Global serving: Multi-Cluster Gateway + Inference Gateway

The front door is a **Multi-Cluster Gateway (MCG)** — a GKE-managed,
cross-region internal Application Load Balancer.

```yaml
gatewayClassName: gke-l7-cross-regional-internal-managed-mc
```

- Single internal VIP, regional presence in every region the gateway
  spans
- Routes `HTTPRoute` targets that can be **Inference Pools** — not just
  Services
- `InferencePool` is the upstream Gateway API Inference Extension CRD; a
  pool in each worker cluster exports itself to the fleet, and the
  management cluster auto-aggregates them into a `GCPInferencePoolImport`

The load balancer does cluster selection. It supports `CUSTOM_METRICS`
balancing, so instead of just latency or connection count, you can spill
between regions on an AI-native signal — **KV-cache utilization**, the
metric that actually predicts when a model server will start degrading.

```yaml
# GCPBackendPolicy on the management cluster
balancingMode: CUSTOM_METRICS
customMetrics:
  - name: gke.named_metrics.kv-cache
    maxUtilizationPercent: 60
```

> Two things worth naming. First, the gateway is doing cluster selection —
> not pod selection. That's deliberate. You want a thin, stateless layer
> doing the wide-area routing and a smarter layer doing the per-pod choice,
> because pod-level decisions benefit enormously from model-server context
> that GCLB doesn't have. Second, the metric matters. "Custom metric
> balancing" is generic, but `kv-cache` is the signal that maps to LLM
> capacity — not latency, not QPS.

---

## 7. Pod-level routing: the Endpoint Picker (EPP)

Behind the gateway, each cluster runs the **Endpoint Picker** — the
Inference Gateway's pod-level router. It's invoked on every request via an
ext_proc extension and makes two decisions: *should we even dispatch this
now?* and *which pod?*

### Scoring plugins — picking the right pod

- **`kv-cache-utilization-scorer`** — prefer the pod with the most room for
  new KV blocks
- **`queue-scorer`** — avoid pods with full local queues
- **`prefix-cache-scorer`** — prefer the pod that already has this prompt's
  prefix cached, skipping prefill compute

> Prefix-cache affinity is the one with no web-serving equivalent. In LLM
> inference, routing a request to a pod that already has similar context
> cached can cut latency by 2–10x. This is why you don't just round-robin
> — you route with model-aware state.

### Flow control — priority and fairness under saturation

EPP v1.4.0 ships a `flowControl` feature gate — it's the part that turns
the gateway from a smart router into a priority queue.

```yaml
saturationDetector:
  queueDepthThreshold: 100
  kvCacheUtilThreshold: 0.90
flowControl:
  maxBytes: 1GB
  defaultRequestTTL: 30s
```

Two headers drive behavior:

| Header | Purpose |
|---|---|
| `x-gateway-inference-objective` | Picks an `InferenceObjective` CRD, which carries a priority |
| `x-gateway-inference-fairness-id` | Tenant ID for fair queuing within a priority band |

`InferenceObjective` is the CRD where application teams declare service
classes:

```yaml
kind: InferenceObjective
metadata: { name: food-review-prod }
spec: { priority: 100 }
```

When the pool saturates (KV > 90% or queue > 100), the EPP stops forwarding
and starts queuing. Production requests (priority 100) dispatch first. Batch
requests (priority -10) wait. Within a band, tenants share fairly. Anything
waiting longer than 30 seconds is shed.

> This is the single most impactful piece of the stack. Without flow control,
> when a pool is overloaded, every request piles into the model server,
> which queues them in arrival order with no priority awareness — your
> $0.10 batch request and your $10 production request both wait equally.
> With flow control, the EPP holds the queue *in front* of the pods and
> dispatches by priority. It protects time-per-output-token for in-flight
> requests and lets you express service tiers without running separate
> deployments per tier.

---

## 8. Scale-to-zero — the EPP makes it possible

One HPA signal is new and it's the key to scale-to-zero for inference:
**`inference_extension_flow_control_queue_size`**.

```yaml
minReplicas: 0
metrics:
  - type: Object
    metric:
      name: inference_extension_flow_control_queue_size
    target: { averageValue: "1" }
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0
    policies:
      - type: Pods
        value: 4
        periodSeconds: 15
```

The flow:

1. Spillover region sits at zero replicas — no GPU cost
2. Primary region saturates; traffic starts arriving at the spillover EPP
3. Spillover EPP has no pods to dispatch to — it **holds the HTTP
   connections in memory** and its flow control queue grows
4. HPA sees queue > 1, fires, scales from 0 → 4 in 15 seconds
5. As pods come ready, the EPP drains the queue — clients never see an
   error

> Scale-to-zero on a traditional web service is table stakes — containers
> start in seconds. On an LLM serving pod, cold start is measured in
> minutes (model download + GPU memory load). Nothing about that is
> acceptable to a client. The EPP's buffering behavior is what makes
> scale-to-zero *safe* for inference: the gateway absorbs cold-start
> latency without dropping connections. This is inference-gateway-specific
> behavior that nothing else in your stack gives you.

---

## 9. Global bin-packing: Kueue and MultiKueue

Serving is half the workload mix. Training and batch jobs are the other
half, and they're the reason GPU utilization is low on most customer
fleets — because they don't get scheduled globally.

**Kueue** is the cluster-local piece. One `ClusterQueue` per cluster, 8
GPUs of quota, three priority classes:

```
training-critical : 2000  (never preempted by inference)
inference-high    : 1000  (preempts training-low)
training-low      : 100   (yields to inference)
```

When the inference HPA asks for another GPU and the cluster is full, Kueue
evicts the cheapest training workload to make room.

**MultiKueue** is the global piece. Training jobs are submitted to a queue
on the *management* cluster. MultiKueue replicates the workload to a
worker cluster that can admit it, watches for completion, and mirrors
status back.

- A single training queue for the whole fleet
- When one region is full, jobs automatically land in another
- When a job gets preempted by inference in one region, it's
  **rescheduled** to another region with capacity — the work isn't
  destroyed, just relocated

Default MultiKueue uses `AllAtOnce` dispatching — it sends a workload to
every cluster and the first to admit wins. That doubles preemption cost:
every cluster preempts, only one wins, the rest throw away work.

For the demo we wrote a **custom dispatcher** that scores clusters by
eviction cost and sends the workload to exactly one — the cluster that
disrupts the least. Scoring is a simple walk of admitted workloads by
priority; running workloads cost 2x to preempt vs. pending. The pluggable
dispatcher API is upstream in Kueue, so you can write your own against the
same extension point.

> The reason MultiKueue matters isn't just bin-packing — it's that it
> closes the loop on preemption. Inference needs a GPU, Kueue evicts a
> training pod, MultiKueue rehomes the training workload to the other
> region. The user submitted one job to one queue and got one completion.
> They never knew three clusters were involved.

---

## 10. Pod snapshotting: making preemption cheap

Preemption is only tolerable if recovery is cheap. For an LLM pod, "recovery"
means re-downloading the model weights and re-loading them onto the GPU —
five to ten minutes on a cold start.

**GKE Pod Snapshotting** (`podsnapshot.gke.io/v1alpha1`) captures the full
pod state — memory, GPU state, filesystem — and restores it on another
node or cluster. For a pre-warmed vLLM pod, that turns a 5-minute cold
start into a sub-30-second restore.

```yaml
apiVersion: podsnapshot.gke.io/v1alpha1
kind: PodSnapshotPolicy
spec:
  storageConfigName: vllm-snapshot-storage   # GCS bucket
  selector:
    matchLabels:
      app: vllm-llama3-8b-instruct
  triggerConfig:
    type: manual
    postCheckpoint: resume
```

**Current status:** the GPU state capture path relies on gVisor GPU
support. There's a known interaction we hit that's tracked upstream, and a
fix is in flight. For the demo we show the flow end-to-end and note where
the polish is landing.

> This is the piece I'm most excited about for the next 12 months. Once
> snapshotting is GA for GPU pods, the whole preemption math changes.
> Today, platform teams set conservative preemption policies because a
> bad eviction costs them hours. With snapshotting, an evicted inference
> pod resumes somewhere else in seconds and the client sees minimal
> impact. That lets you run training much more aggressively on the same
> fleet — real utilization gains, not rhetorical ones.

---

## 11. Faster starts: Image Streaming

Model weights aren't the only big thing a pod pulls. The vLLM container
image itself is multi-gigabyte (CUDA toolkit, PyTorch, attention backends,
model-loading libs).

**GKE Image Streaming** mounts the container image over a FUSE filesystem
and streams layers on-demand instead of downloading the whole image before
the container starts.

- The container enters `Running` within seconds of being scheduled
- Layers are pulled lazily as the process reads them
- Second pod on the same node benefits from the node-local cache

Combined with pod snapshotting, this collapses the "scheduled → serving
traffic" window dramatically:

| Without | With image streaming + snapshot |
|---|---|
| Pull image: 30–90s | Pull image: 2–5s (stream) |
| Download model: 60–180s | Restore snapshot: 10–30s |
| Load model to GPU: 30–120s | *(included in restore)* |
| **Total: 2–7 min** | **Total: ~30s** |

> The reason these two features belong together is that they attack
> different phases of the same problem. Image streaming fixes "pod
> scheduled → process running." Snapshotting fixes "process running →
> model loaded." Together they make GPU pods behave more like web pods —
> which is the prerequisite for aggressive autoscaling and preemption
> policies actually being usable.

---

## 12. Putting it together: the demo

Three acts, live, ~8 minutes:

**Act 1 — MultiKueue bin-packs training jobs.**
I submit three training jobs, each 2 GPUs. The first two land in east1.
The third doesn't fit east1; the dispatcher scores both clusters, sees
west3 has capacity and no running work to displace, and nominates west3.
One submission, one queue, global placement.

**Act 2 — Serving reclaims GPUs from training.**
Inference load on east1 ramps. KV cache climbs. HPA fires, needs another
GPU. East1 is full. Kueue evicts a `training-low` job. New inference pod
starts on the freed GPU. The evicted training job gets rescheduled by
MultiKueue to west3 where there's capacity. Serving got its GPU. Training
kept its work. No human intervened.

**Act 3 — Priority at the request layer.**
Load keeps ramping. East1 hits 90% KV-cache. EPP saturation trips. Two
streams of traffic are live — production (priority 100) and batch
(priority -10). The dashboard shows production flowing through with
sub-second latency while the batch queue grows. Some batch requests hit
the 30-second TTL and get shed. Production is protected.

> Everything on the dashboard is real scraped state. If the demo breaks,
> it breaks in public. That's also why it's worth your time — you're not
> watching a recording.

---

## 13. What this unlocks for your platform

- **One endpoint, one quota, one priority model** across your GPU fleet —
  your application teams don't need to know the topology
- **Higher utilization** — serving and training share the same GPUs without
  fighting
- **Scale-to-zero for inference** — regional spillover capacity that costs
  nothing until it's needed
- **Work preservation** under preemption — evicted training jobs
  redistribute instead of getting killed
- **Service tiers via headers** — expose priority to app teams without
  running separate deployments per tier

Every component is either **GKE-managed** (MCG, Fleets, Image Streaming,
Pod Snapshotting) or **upstream open-source** (Gateway API Inference
Extension, Kueue, MultiKueue, ClusterProfiles). Nothing you see is locked
into a proprietary path. You can lift the pattern to another environment;
GKE just removes the parts you'd otherwise have to operate yourself.

---

## 14. Where this is heading

- **Pod snapshotting for GPU workloads** — GA path is in flight; collapses
  preempt-and-recover to sub-minute
- **More scoring plugins for EPP** — cost-aware and latency-SLO-aware
  routing are active upstream work
- **Broader InferenceObjective semantics** — TTFT/TPOT SLOs as first-class
  fields, not just priority
- **Tighter Fleet integration for MultiKueue** — ClusterProfile-native
  cluster discovery, less bespoke wiring
- **Customer-driven dispatcher patterns** — Kueue's pluggable dispatcher
  API means you can encode your own placement policy today; we're seeing
  customers pattern ours

> If you're evaluating any of this for your own fleet, the two pieces I'd
> start with are (1) Inference Gateway with flow control — even in a
> single cluster, the priority and fairness story is transformative, and
> (2) Kueue for GPU quota. Everything else composes on top of those two.

---

## 15. Resources

- GKE Multi-Cluster Gateway: `gke-l7-cross-regional-internal-managed-mc`
- Gateway API Inference Extension (upstream)
- Kueue + MultiKueue (upstream `sigs.k8s.io/kueue`)
- GKE Fleets + SIG Multicluster ClusterProfile
- GKE Image Streaming
- GKE Pod Snapshotting (preview)
- Demo repo (manifests, custom dispatcher, load test + dashboard): link
- Contact: your email / GKE TAM

> Thank you. I'm around for the rest of the conference — happy to dig into
> any of the components with you. If you have a workload in mind and want
> to sketch how it'd map to this pattern, grab me.
