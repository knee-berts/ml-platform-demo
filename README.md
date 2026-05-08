# Multi-Cluster Inference Gateway + Flow Control + Kueue Preemption Demo

Live demo of GKE's Multi-Cluster Inference Gateway with KV-cache-aware routing, EPP flow control for request-level prioritization, and Kueue-based GPU preemption. The default ("happy path") deployment runs on NVIDIA L4 GPUs provisioned by Node Auto-Provisioning; an opt-in static-pool mode targets NVIDIA RTX PRO 6000 Blackwell when you have quota and a reservation.

## What This Demo Shows

Two GKE worker clusters each run vLLM inference pods serving `meta-llama/Llama-3.1-8B-Instruct` with LoRA adapters. A management cluster ties them together with a cross-region gateway, MultiKueue federation, and an Endpoint Picker (EPP v1.4.0) with flow control for intelligent, priority-aware request routing.

The demo has three acts:

1. **MultiKueue Training Distribution** — Submit training jobs to the management cluster. MultiKueue evaluates GPU capacity across both workers and dispatches each job to a cluster with room.

2. **Inference Preemption Under Load** — Blast one cluster with inference traffic. Its KV cache fills up, the HPA scales out new inference pods, and Kueue preempts lower-priority training jobs to free GPUs. The evicted training job gets rescheduled by MultiKueue to the other cluster that still has capacity.

3. **Flow Control & Request Prioritization** — Under heavy load, the EPP's saturation detector engages and holds requests in memory. Production requests (`food-review-prod`, priority 100) dispatch ahead of batch requests (`food-review-batch`, priority -10). Fair queuing ensures no single tenant monopolizes capacity within a priority band.

### Architecture

```
                         ┌──────────────────┐
                         │  Management GKE  │
                         │  (Standard)      │
                         │  Gateway + Route │
                         │  MultiKueue      │
                         │  GCPBackendPolicy│
                         └────────┬─────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    ▼                           ▼
          ┌─────────────────┐           ┌─────────────────┐
          │  worker-east1   │           │  worker-<other> │
          │  (Standard)     │           │  (Standard)     │
          │  vLLM pods      │           │  vLLM pods      │
          │  EPP v1.4.0     │           │  EPP v1.4.0     │
          │  Flow Control   │           │  Flow Control   │
          │  InferencePool  │           │  InferencePool  │
          │  Kueue queues   │           │  Kueue queues   │
          │  HPA            │           │  HPA            │
          └─────────────────┘           └─────────────────┘
```

GPUs come from one of two paths, configured per worker in `1-infrastructure/`:

- **Happy path (default):** no fixed GPU pool. The `inference-gpu` ComputeClass drives Node Auto-Provisioning to materialize `g2-standard-12` (L4) Spot or on-demand pools when GPUs are requested, and the cluster autoscaler drains them between demo runs.
- **Static accelerator pool (opt-in):** set `static_accelerator_machine_type` (`g4-*` for Blackwell, `g2-*` for L4) to attach a fixed pool to every worker. Required for Blackwell — pair with a reservation in each worker region.

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

- `kubectl` with contexts configured: `mgmt`, `worker-<region>` for each worker. `scripts/install.sh` sets these up automatically.
- Python 3.8+ with `rich` installed (`pip install rich`)
- A deployed instance of the three Terraform stacks (see [Infrastructure Setup](#infrastructure-setup))

## Running the Demo

The demo is a two-step process: first set up training jobs, then run the load test.

### Step 1: Reset the Environment

Always start clean. The `--target` flag controls which cluster the load test will saturate (and therefore which cluster gets more HPA headroom).

```bash
./demo-reset.sh --target east1
```

This:
- Kills any running load generator pods
- Scales inference back to 4 replicas per cluster
- Clears all training jobs
- Restores ClusterQueue GPU quotas
- Sets HPA limits (target cluster max=6, other max=4)

### Step 2: Submit Training Jobs (MultiKueue Demo)

```bash
./demo-multikueue.sh --target east1
```

This is an interactive, narrated walkthrough that:

1. Shows the current GPU allocation across both clusters (4 inference pods each = 4 GPUs used, 4 free)
2. Submits `training-job-1` (2 GPUs) — MultiKueue dispatches to the target cluster
3. Submits `training-job-2` (2 GPUs) — MultiKueue dispatches to the target cluster (now full: 4 inf + 4 train = 8/8)
4. Submits `training-job-3` (2 GPUs) — Target is full, so MultiKueue dispatches to the other cluster
5. Shows final state: target has 0 free GPUs, other has 2 free GPUs (room for rescheduled jobs later)

Add `--auto` for an unattended version with timed pauses (good for recordings).

### Step 3: Run the Load Test + Dashboard

```bash
python3 load_test.py --target-cluster east1 --concurrency 300
```

This launches load generator pods inside the target cluster and opens a live Rich dashboard showing:

- **Cluster panels** — Per-pod KV cache utilization bars, running/waiting request counts, fill rate, sparkline history
- **Routing panel** — Which cluster is the load target vs. spillover destination, threshold status
- **EPP Flow Control panel** — Per-cluster EPP queue depth bars, saturation status, active InferenceObjective and fairness IDs
- **Kueue panel** — HPA replica counts and scaling metrics, workload table with cluster/type/status, training pod counts, and a live event log showing preemptions and rescheduling
- **Stats panel** — Load generator target, concurrency, success/error counts, RPS

> **Note:** `demo-reset.sh`, `demo-multikueue.sh`, and `load_test.py` currently reference the cluster contexts `worker-east1` and `worker-west3`. If you deploy with the install.sh defaults (`us-east1` + `us-central1`) you'll need to update those scripts to use `worker-central1` instead, or override `WORKER_REGIONS=us-east1 us-west3` at install time. `demo-preemption.sh` has already been updated to `east1` + `central1`.

The demo's training JobSets and the inference HPA live as reusable YAML templates in [`workers/`](workers/) and are rendered at demo time with `envsubst`:

| File | Used by | Variables |
|---|---|---|
| `workers/hpa-inference.yaml` | `demo-preemption.sh` (preflight) | none |
| `workers/training-job.yaml` | `demo-multikueue.sh::submit_job` | `JOB_NAME`, `JOB_NUM` |
| `workers/experiment.yaml` | `demo-preemption.sh::submit_small_job` | `JOB_NAME`, `JOB_NUM` |
| `workers/critical-pretraining.yaml` | `demo-preemption.sh::submit_critical_job` | `JOB_NAME` |

### What You'll See

As load ramps up on the target cluster:

1. KV cache fills toward the 60% threshold
2. HPA detects high utilization and requests more inference replicas
3. No free GPUs on the target cluster — Kueue preempts a `training-low` job to free a GPU
4. New inference pod starts on the freed GPU
5. The evicted training job gets rescheduled by MultiKueue to the other cluster
6. Events panel shows: `PREEMPTED: training-job-2-xxxxx evicted on east1` followed by `RESCHEDULED: training-job-2-xxxxx → <other>`

### Dashboard Modes

The dashboard can run independently of the load test:

```bash
# Dashboard only — monitor clusters without generating any load
python3 load_test.py --mode dashboard --target-cluster east1

# Load only — generate load with periodic text stats (no Rich UI)
python3 load_test.py --mode load --target-cluster east1 --concurrency 300

# Both (default) — full experience
python3 load_test.py --mode both --target-cluster east1 --concurrency 300
```

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

The infrastructure spans three GKE Standard clusters (one management hub plus N workers, default 2).

### Quick install (one command)

`scripts/install.sh` provisions the full demo in any GCP project:

```bash
export PROJECT_ID=your-gcp-project
export HF_TOKEN=hf_xxx     # https://huggingface.co/settings/tokens

# Optional: opt into a static accelerator pool (default = NAP-driven L4)
# export STATIC_ACCELERATOR_MACHINE_TYPE=g4-standard-48
# export STATIC_ACCELERATOR_RESERVATION=blackwell-demo-reservation

./scripts/install.sh
```

The script:

1. Enables required APIs.
2. `terraform apply` for [`1-infrastructure/`](1-infrastructure/) — Standard clusters, fleet, IAM, AR repos, GCS buckets.
3. Cloud-Builds and pushes 4 images to the project's Artifact Registry: `gcp-auth-plugin`, `kueue-with-gcp-auth`, `least-disruption-dispatcher`, `vllm-blackwell`. The vLLM image picks `Dockerfile.l4` by default; `g4-*` machine types switch it to `Dockerfile.blackwell` (override with `VLLM_DOCKERFILE`).
4. Cloud-Build job downloads Llama 3.1 8B from HuggingFace using `HF_TOKEN` and uploads to `gs://<project>-model-weights/`.
5. `terraform apply` for [`2-multikueue/`](2-multikueue/) — Kueue + JobSet + LWS + dispatcher across all clusters.
6. `terraform apply` for [`3-multi-cluster-inference-gateway/`](3-multi-cluster-inference-gateway/) — cross-region Gateway + EPP + InferencePool + vLLM Deployment + HF Secret.
7. Renames kubectl contexts to `mgmt` / `worker-<region>` for each cluster.
8. Runs `demo-preemption.sh` (skip with `SKIP_DEMO=1`).

Wall-clock: ~30–45 min, dominated by GKE cluster creation, vLLM image push, and weights download.

**Requirements:** Owner role on the project, GPU quota in each worker region (`NVIDIA_L4_GPUS >= 8` for the happy path, or `NVIDIA_RTX_PRO_6000_GPUS >= 8` and a reservation for Blackwell), and a HuggingFace token that has accepted the [Llama 3.1 license](https://huggingface.co/meta-llama/Llama-3.1-8B-Instruct).

### Layered Terraform stacks

The script wraps three Terraform stacks. Each is also runnable standalone — see each stack's `README.md`.

| Stack | What it provisions |
|---|---|
| [`1-infrastructure/`](1-infrastructure/) | GCP infrastructure: project services, proxy subnets, cluster SAs + IAM, Workload Identity bindings, multi-cluster ingress feature, GKE Standard clusters (mgmt + workers), GCS buckets (`model-weights`, `pod-snapshots`), and Artifact Registry repos (`vllm-blackwell`, `gcp-auth-plugin`). Static accelerator pools are opt-in via `static_accelerator_machine_type` (`g4-*` for Blackwell, `g2-*` for L4); the default happy path runs on NAP-driven L4. |
| [`2-multikueue/`](2-multikueue/) | In-cluster Kueue + MultiKueue control plane via the Helm provider: Kueue, JobSet, LeaderWorkerSet operators on every cluster; demo's WorkloadPriorityClasses, ResourceFlavor, ClusterQueue, LocalQueues; AdmissionCheck, MultiKueueConfig, MultiKueueClusters, ClusterProfiles on the hub; `least-disruption-dispatcher` Deployment. |
| [`3-multi-cluster-inference-gateway/`](3-multi-cluster-inference-gateway/) | In-cluster routing + application via Helm: cross-region Gateway, HTTPRoute + GCPBackendPolicy + HealthCheckPolicy on the hub; per-worker InferencePool, InferenceObjectives, EPP, ComputeClass, AutoscalingMetric, vLLM Deployment + HF token Secret. The HPA is intentionally not part of the chart — `demo-preemption.sh` applies `workers/hpa-inference.yaml` at demo start and removes it at cleanup so the GPU pool drains between runs. |

### GPU compute classes

The `inference-gpu` ComputeClass (installed by stack 3) defines the priority list the inference Deployment selects on. Default tiers:

1. **L4 Spot** (NAP-driven `g2-standard-12`)
2. **L4 on-demand** (NAP fallback when Spot capacity is unavailable)

When `enable_blackwell_compute_class_tier=true` is set on stack 3, a Blackwell tier is prepended to match a `g4-*` static accelerator pool. `activeMigration` repacks pods back to higher-priority tiers when capacity returns.

### Building the vLLM Image

Two example Dockerfiles ship at the repo root, each layering family-specific
defaults on top of `vllm/vllm-openai`:

| File | When to use | Notes |
|---|---|---|
| `Dockerfile.l4` | Happy path (NAP-driven L4) and any `g2-*` static pool | FA2 backend, no FlashInfer install. Pair with runtime args `--kv-cache-dtype fp8 --gpu-memory-utilization 0.95 --max-model-len 2048` to fit Llama 3.1 8B on 24 GB. |
| `Dockerfile.blackwell` | `g4-*` static pool (RTX PRO 6000, sm_120) | FlashInfer attention backend, expandable_segments allocator. Bumps to higher `--max-num-seq` are safe given 96 GB VRAM. |

The base image is multi-arch (sm_75–sm_120), so either build will run on the
other family if needed; the runtime env defaults differ.

```bash
# L4 / happy path
docker build -f Dockerfile.l4 \
  -t us-east1-docker.pkg.dev/<project>/vllm-blackwell/vllm-blackwell:latest .

# Blackwell static pool
docker build -f Dockerfile.blackwell \
  -t us-east1-docker.pkg.dev/<project>/vllm-blackwell/vllm-blackwell:latest .

docker push us-east1-docker.pkg.dev/<project>/vllm-blackwell/vllm-blackwell:latest
```

`scripts/install.sh` picks the right Dockerfile automatically based on
`STATIC_ACCELERATOR_MACHINE_TYPE` (override with `VLLM_DOCKERFILE`).

### Connecting to Clusters

```bash
gcloud container clusters get-credentials ai-worker-<region> \
  --region <region> --project <project>
```

Or use `terraform output -raw get_credentials_commands` from `1-infrastructure/` to print the full set.

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
