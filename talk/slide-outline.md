# Slide Outline: "From Web Apps to AI — What Changes and What Doesn't"

---

## SLIDE 1 — Title
**"From Web Apps to AI — What Changes and What Doesn't"**
- Subtitle: A platform engineer's guide to multi-cluster GPU orchestration on Kubernetes
- Your name / role / event

---

## SLIDE 2 — Who this talk is for
- Platform engineers running serving and batch workloads on Kubernetes
- Curious about AI/ML infrastructure but haven't built it yet
- Want to understand what's familiar, what's new, and where the real complexity lives

---

## SLIDE 3 — AI workloads through a platform lens
- Inference is a form of serving — request in, response out, latency matters
- Training is a form of batch — claim resources, run to completion, throughput matters
- GPUs are a scarce, expensive resource — utilization and priority matter more than with CPUs
- Some of the platform patterns carry over. Some don't. Let's look at both.

---

## SLIDE 4 — The demo platform (architecture overview)
- Diagram: 3 GKE clusters (mgmt, east1, west3)
- 8x RTX PRO 6000 Blackwell per worker cluster
- Model: Llama-3.1-8B-Instruct + LoRA adapter
- Stack: Gateway API, EPP with flow control, Kueue/MultiKueue, HPA
- Mix of general Kubernetes tooling and AI-specific extensions

---

## SLIDE 5 — Three platform problems
- **Multi-cluster routing**: How do you send traffic to the right cluster?
- **Resource contention**: What happens when serving needs capacity that batch is using?
- **Request prioritization**: When the backend is saturated, who gets served first?

These show up in any platform. The way you solve them for AI workloads has overlap with traditional approaches — and some important differences.

---

## SLIDE 6 — Problem 1: Multi-cluster traffic routing

**How it works here:**
- GCLB routes across regions using `GCPBackendPolicy` with `CUSTOM_METRICS` balancing
- Metric: KV-cache utilization (how full the model's working memory is)
- When east1 crosses 60%, traffic ramps to west3

```yaml
balancingMode: CUSTOM_METRICS
customMetrics:
  - name: gke.named_metrics.kv-cache
    maxUtilizationPercent: 60
```

**What's familiar:** The routing mechanism is workload-agnostic. `CUSTOM_METRICS` balancing works with any exported metric — request latency, connection count, queue depth. The YAML would look nearly identical for a web app.

**What's different:** The *metric* is AI-specific. KV-cache utilization reflects how much GPU memory the model is using for in-flight requests. Choosing the right metric and threshold requires understanding LLM serving characteristics.

---

## SLIDE 7 — Three-tier routing deep dive
- **Tier 1: GCLB** — which cluster? Custom metric threshold. General-purpose mechanism.
- **Tier 2: EPP flow control** — queue and prioritize requests when saturated. The pattern is general (L7 priority queuing), but the saturation signals are AI-specific (KV-cache %, inference queue depth).
- **Tier 3: EPP scoring** — which pod? KV-cache utilization, prefix-cache affinity, queue depth. This tier is purpose-built for LLM serving — prefix-cache affinity has no equivalent in traditional web serving.

Callout: The tiers range from fully general (Tier 1) to fully AI-specific (Tier 3). Understanding where that boundary falls helps you know which skills transfer and where you need to build new expertise.

---

## SLIDE 8 — Problem 2: Priority preemption

**How it works here:**
- Kueue manages GPU quota per cluster (8 GPUs each)
- Three priority levels control preemption:

```
training-critical:  2000   — cannot be preempted
inference-high:     1000   — preempts training-low
training-low:        100   — yields to inference when GPUs are needed
```

```yaml
preemption:
  withinClusterQueue: LowerPriority
resourceGroups:
  - coveredResources: ["nvidia.com/gpu"]
    nominalQuota: 8
```

**What's familiar:** Kueue's quota and preemption model works with any resource — CPUs, GPUs, TPUs. The priority class pattern is the same one you'd use for web serving vs. batch ETL. The ClusterQueue doesn't have GPU-specific logic.

**What's different:** The cost of preemption is much higher for GPU workloads. Training jobs can run for hours; evicting one wastes significant compute. Inference pods take minutes to cold-start (model download + GPU load), so preempting inference has a real recovery cost too. This changes how you set priorities and thresholds.

---

## SLIDE 9 — MultiKueue: cross-cluster job placement

- Training job needs 2 GPUs, east1 is full → MultiKueue dispatches to west3
- Custom dispatcher scores clusters by eviction cost:
  ```
  cost = gpu_count × priority_weight × status_multiplier
  ```
- Running workloads cost double to evict (in-progress work lost)

**What's familiar:** Cross-cluster job placement is the same bin-packing problem you'd solve for distributing Spark or Airflow jobs. The scoring algorithm is resource-agnostic — it operates on numeric counts and priority values.

**What's different:** GPU workloads are coarse-grained. A single training job might consume 2-4 GPUs out of 8 total. Compared to CPU workloads where you might pack dozens of pods per node, every GPU scheduling decision has outsized impact on cluster capacity. The dispatcher needs to be more careful about placement because the margin for error is thin.

---

## SLIDE 10 — Problem 3: Request-level priority under saturation

**How it works here:**
- EPP saturation detector triggers at KV-cache > 90% or queue depth > 100
- Requests queued by priority via HTTP headers:
  ```
  x-gateway-inference-objective: food-review-prod  → priority 100
  x-gateway-inference-objective: food-review-batch  → priority -10
  x-gateway-inference-fairness-id: tenant-abc       → fair queuing
  ```
- TTL of 30s — requests waiting longer are shed

**What's familiar:** Priority queuing with fair sharing within tiers. Same pattern as API gateway rate limiting where premium consumers get priority and each consumer within a tier gets a fair share.

**What's different:** The saturation signals are AI-specific. KV-cache utilization and model server queue depth reflect GPU memory pressure and batch scheduling — these don't have direct analogs in traditional web serving. Tuning these thresholds requires understanding how LLM inference engines manage memory and batching internally.

---

## SLIDE 11 — Scale-to-zero spillover

West3 HPA with `minReplicas: 0`:
```yaml
metrics:
  - type: Object  # EPP flow control queue depth
    target:
      averageValue: "1"
scaleUp:
  stabilizationWindowSeconds: 0
  policies:
    - type: Pods
      value: 4
      periodSeconds: 15
```

**What's familiar:** Scale-from-zero on a queue depth metric. Same pattern as KEDA scaling consumers from zero when an SQS or Pub/Sub queue grows. The HPA configuration is standard.

**What's different:** Cold start is measured in minutes, not seconds. The model needs to download (potentially gigabytes) and load onto GPU memory. The EPP buffers HTTP connections in memory during this window so clients don't get errors — this is a pattern specific to inference gateways where you need to absorb minutes of cold-start latency without dropping requests. Your scale-up policy needs to be aggressive (4 pods per 15s, zero stabilization) because every second of delay means requests queuing.

---

## SLIDE 12 — DEMO TIME
- Title card before switching to terminal
- Three acts:
  1. **MultiKueue** distributes training jobs across clusters
  2. **Inference load** triggers HPA scale-up, Kueue preempts training
  3. **EPP flow control** engages — prod served first, batch waits

---

## SLIDES 13-15 — Demo (live or recorded)
- Use `preemption-demo.gif` or live `demo-preemption.sh`
- Narrate each act, calling out:
  - Act 1: Where the scheduling behavior is general vs. GPU-specific
  - Act 2: The high cost of preemption (minutes to recover) compared to CPU workloads
  - Act 3: How saturation detection differs from traditional health checks

---

## SLIDE 16 — What's genuinely new in AI platforms

These don't have clean analogs in traditional serving or batch:

- **KV-cache as a routing signal** — LLMs maintain per-request state in GPU memory. Routing decisions based on this memory pressure are unique to inference serving.
- **Prefix-cache affinity** — Routing a request to the pod that already has similar context cached, avoiding redundant computation. No web serving equivalent.
- **LoRA adapter hot-swap** — Loading fine-tuned model variants at runtime without restart. Like hot-swapping business logic per request.
- **Multi-minute cold starts** — Model download + GPU memory allocation. Changes how you think about autoscaling, preemption cost, and readiness.
- **GPU memory management** — `/dev/shm` mounts, CUDA allocator tuning (`expandable_segments`), device plugins. New operational surface area that doesn't exist for CPU workloads.
- **Continuous batching** — The model server interleaves decode steps across concurrent requests to maximize GPU utilization. Scheduling happens inside the server, not just at the platform layer.

These are real complexity that requires new expertise. Minimizing them doesn't help anyone.

---

## SLIDE 17 — What transfers directly

These work the same way regardless of workload type:

| Component | How it's used here | Works for non-AI workloads? |
|---|---|---|
| Gateway API + GCPBackendPolicy | Custom-metric cross-region routing | Yes — swap the metric for latency, error rate, etc. |
| Kueue / MultiKueue | GPU quota + priority preemption | Yes — works with any resource type |
| HPA on custom metrics | Scale on KV-cache utilization | Yes — any Prometheus metric |
| PriorityClass | Inference preempts training | Yes — built into Kubernetes since 1.14 |
| EPP flow control (pattern) | Priority queuing at L7 | Pattern applies to any saturated API |

These tools were designed to be workload-agnostic. If you're not already using Kueue or custom-metric Gateway routing for your traditional workloads, this is worth looking at independently of AI.

---

## SLIDE 18 — Where you need new skills

| Area | What's new | Depth required |
|---|---|---|
| GPU device management | Device plugins, CUDA drivers, shared memory, multi-instance GPU | Medium — mostly operational |
| Model serving internals | KV-cache, continuous batching, prefix caching, LoRA | Deep — needed for tuning and debugging |
| Capacity planning | Coarse-grained resources (1 GPU vs. 100 millicores), long cold starts | Medium — changes your scaling math |
| Cost management | GPU-hours are 10-100x CPU-hours; idle GPUs are expensive | High — the financial stakes are different |
| Metrics and observability | New metrics (KV-cache, TPOT, TTFT, batch utilization) | Medium — familiar tooling, new signals |

---

## SLIDE 19 — Practical takeaways
1. **Audit your existing tools.** Kueue, Gateway API custom metrics, HPA — if you're not using these for your current workloads, start there. They'll serve you for AI workloads too.
2. **Invest in understanding model serving.** The platform layer transfers. The workload layer (KV-cache, batching, LoRA) requires genuine new learning. Don't skip it.
3. **Respect the cost of preemption.** GPU cold starts change the math. A preemption policy that works fine for 200ms container startups needs rethinking when recovery takes 5 minutes.
4. **The tools are converging.** Kueue, Gateway API Inference Extension, and MultiKueue are upstream Kubernetes projects. The ecosystem is building toward a single platform layer for all workload types.

---

## SLIDE 20 — Resources / links
- Repo link
- Gateway API Inference Extension docs
- Kueue / MultiKueue docs
- EPP flow control documentation
- Your contact info
