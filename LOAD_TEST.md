# load_test.py — KV-Cache Spillover, Flow Control & Kueue Preemption Demo

## Overview

`load_test.py` is a ~1,700-line Python script that drives and visualizes the multi-cluster inference demo. It has three jobs: generate inference load with flow control headers against a GKE cluster through the cross-region gateway VIP, scrape EPP flow control metrics, and render a live terminal dashboard showing what's happening across both worker clusters in real time.

## How It Works

### Architecture

The script runs several concurrent threads, each responsible for a different aspect of the demo:

```
┌─────────────────────────────────────────────────────────────────┐
│  Main Thread                                                    │
│  └── Rich Live dashboard (renders at 2 fps)                     │
│                                                                 │
│  MetricsCollector (thread per cluster)                          │
│  └── kubectl exec into each vLLM pod → scrape /metrics          │
│      → KV cache %, running/waiting requests                     │
│  └── Also scrapes EPP pod metrics (via vLLM pod curl + bearer)  │
│      → flow_control_queue_size, queue_duration, saturated        │
│                                                                 │
│  KueueCollector (thread)                                        │
│  └── kubectl get workloads on worker-east1, worker-west3, mgmt  │
│      → detects preemption (Requeued=True), new inference pods   │
│      → kubectl get hpa, training pods                           │
│                                                                 │
│  VipProber (thread)                                             │
│  └── HTTP requests through VIP → tracks which cluster responds  │
│      → includes x-gateway-inference-objective header             │
│                                                                 │
│  RequestCounter (thread)                                        │
│  └── Polls vLLM success counters to estimate RPS                │
│                                                                 │
│  Load Generator (runs inside cluster as pods)                   │
│  └── Spawned via kubectl run, sends concurrent requests to VIP  │
│      from within the target cluster (geographic affinity)       │
│      Each worker sends flow control headers:                    │
│        x-gateway-inference-objective: <--objective flag>         │
│        x-gateway-inference-fairness-id: tenant-{wid % 8}        │
└─────────────────────────────────────────────────────────────────┘
```

### Modes

| Mode | What it does |
|---|---|
| `--mode both` (default) | Runs the load generator pod + live dashboard |
| `--mode dashboard` | Dashboard only — monitor without generating load |
| `--mode load` | Load only — periodic text stats, no Rich UI |

### Load Generation

The script creates multiple load pods (`kv-load-gen-{cluster}-{n}`) inside the target cluster using `kubectl run`, splitting concurrency across them. Each pod runs a Python script that sends concurrent HTTP requests to the gateway VIP from within the cluster. Each request includes:

- A unique 48-character random prefix (`[REQID:...]`) to prevent KV-cache block reuse — every request forces fresh KV block allocation
- `x-gateway-inference-objective` header (from `--objective` flag, default `food-review-prod`) — tells the EPP which InferenceObjective to use for priority
- `x-gateway-inference-fairness-id` header (`tenant-{wid % 8}`) — gives each worker a stable tenant ID for fair queuing within the priority band

The load pods run inside the cluster (not locally) so that GCLB's geographic affinity routes requests to the nearest cluster, which is the target cluster itself.

#### Steady-State Load Pattern

The load generator is designed to produce smooth, sustained KV-cache utilization rather than bursty spikes. This is critical for GCLB's custom-metric-based routing — GCLB needs to see sustained above-threshold utilization across multiple consecutive metric samples before it shifts traffic to another region.

Two mechanisms prevent request lockstep:

1. **Staggered worker startup** — Each worker thread delays by a random amount (up to 60 seconds) before sending its first request. This spreads the initial burst across a wide window so workers enter their request loops at different times.

2. **Randomized token count** — Each request generates `max_tokens +/- 25%`. With different generation lengths, workers complete at different times even if they started together, preventing the "all finish at once, all fire at once" pattern.

Without these, all workers fire simultaneously, all requests complete at roughly the same time (same token count = same generation duration), and the KV cache sawtooths between 0% and 99%. GCLB may sample during a trough and never trigger spillover.

### Metrics Collection

`MetricsCollector` threads run `kubectl exec` into each vLLM pod every 2 seconds and parse the Prometheus `/metrics` endpoint. Extracted vLLM metrics:

- `vllm:gpu_cache_usage_perc` / `vllm:kv_cache_usage_perc` — KV cache utilization (0.0–1.0)
- `vllm:num_requests_running` — in-flight requests
- `vllm:num_requests_waiting` — queued requests

In parallel, the collector scrapes EPP flow control metrics from each cluster's EPP pod. Since the EPP runs in a distroless container (no curl/wget), the scrape is done by exec-ing into a vLLM pod and curling the EPP service with a bearer token from the `metrics-reader-secret`. Extracted EPP metrics:

- `inference_extension_flow_control_queue_size` — requests buffered in EPP flow control queue
- `inference_extension_flow_control_request_queue_duration_seconds` — average time requests spend in queue
- `inference_extension_flow_control_saturated` — whether the saturation detector has tripped

These are stored in `EppState` (per-cluster `EppMetrics` dataclass) and rendered in the dashboard's EPP Flow Control panel.

### Kueue Event Detection

`KueueCollector` polls three kubectl contexts every ~5 seconds:

- **Worker clusters** (`worker-east1`, `worker-west3`): Gets all Kueue workloads to populate the dashboard table and detect new inference pods
- **Management cluster** (`mgmt`): Gets training workload conditions — specifically the `Requeued` flag, which is the stable signal for preemption (the `Evicted` flag is transient and unreliable to poll)

Events detected:
- **NEW**: A previously unseen inference workload appears on a worker
- **PREEMPTED**: A training workload's `Requeued` condition becomes `True` on mgmt
- **RESCHEDULED**: The preempted training workload appears on a different worker cluster

### Dashboard

The Rich terminal UI is a fixed layout with five sections:

1. **Cluster panels** (left/right) — Per-pod KV cache utilization bars, running/waiting counts, sparkline history
2. **Routing panel** — Target vs spillover cluster, threshold status, VIP probe results
3. **EPP Flow Control panel** — Per-cluster queue depth bars, saturation status, active InferenceObjective and fairness ID configuration, average queue wait time
4. **Kueue panel** — HPA status, workload table (cluster/name/type/status/GPUs), training pod counts, timestamped event log
5. **Stats panel** — Load target, concurrency, success/error counts, RPS

## Libraries

### External (requires install)

| Library | Version | Purpose |
|---|---|---|
| [rich](https://github.com/Textualize/rich) | any recent | Terminal UI: `Live` display, `Layout` grid, `Panel`, `Text` styling, `Table` rendering |

Install: `pip install rich`

### Standard Library

| Module | Purpose |
|---|---|
| `argparse` | CLI argument parsing |
| `threading` | Concurrent metrics collection, Kueue polling, VIP probing, request counting |
| `subprocess` | `kubectl` commands (exec, get, run, delete) |
| `urllib.request` | HTTP requests for VIP probing |
| `json` | Parsing kubectl JSON output and VIP probe responses |
| `dataclasses` | Data containers for pod metrics, cluster state, load stats |
| `time` | Intervals, timestamps, elapsed time calculation |
| `re` | Regex for parsing Prometheus metrics and shortening workload names |
| `signal` | Graceful shutdown on Ctrl-C |
| `textwrap` | Formatting the inline load generator script |

## Key Design Decisions

- **Load runs inside the cluster**: The load generator pods run within the target worker cluster so GCLB's geographic affinity sends traffic to that cluster first. Running locally would bypass this behavior.
- **Unique prompts per request**: Each request has a random prefix to prevent prefix-cache reuse, ensuring every request allocates fresh KV-cache blocks.
- **Staggered workers + randomized tokens**: Workers start at staggered intervals and each request varies `max_tokens` by +/-25%. This produces smooth, sustained KV-cache utilization instead of bursty spikes that GCLB can't react to.
- **Flow control headers per worker**: Each worker gets a stable `fairness_id` (`tenant-{wid % 8}`) so the EPP can demonstrate per-tenant fair queuing. The `--objective` flag controls the priority level of all requests in a load run.
- **EPP scraping via vLLM pods**: The EPP container is distroless (no shell/curl). Metrics are scraped by exec-ing curl from a vLLM pod to the EPP service endpoint, authenticating with a bearer token from the `metrics-reader-secret`. Token is cached per kubectl context.
- **Mgmt cluster for preemption detection**: Worker workloads just disappear when preempted. The management cluster's `Requeued=True` condition is the only reliable, sticky signal.
- **Screen-mode Rich layout**: Uses `Live(screen=True)` for a full-terminal dashboard that updates in place without scrolling.
- **Model streaming from GCS**: vLLM loads model weights directly from Cloud Storage using the Run:ai Model Streamer (`--load-format=runai_streamer`), reducing pod startup from minutes to ~3 seconds.
