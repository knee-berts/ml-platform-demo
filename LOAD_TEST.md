# load_test.py — KV-Cache Spillover & Kueue Preemption Demo

## Overview

`load_test.py` is a ~1,400-line Python script that drives and visualizes the multi-cluster inference demo. It has two jobs: generate inference load against a GKE cluster through the cross-region gateway VIP, and render a live terminal dashboard showing what's happening across both worker clusters in real time.

## How It Works

### Architecture

The script runs several concurrent threads, each responsible for a different aspect of the demo:

```
┌─────────────────────────────────────────────────────────────────┐
│  Main Thread                                                    │
│  └── Rich Live dashboard (renders at 2 fps)                    │
│                                                                 │
│  MetricsCollector (thread per cluster)                          │
│  └── kubectl exec into each vLLM pod → scrape /metrics         │
│      → KV cache %, running/waiting requests                    │
│                                                                 │
│  KueueCollector (thread)                                        │
│  └── kubectl get workloads on worker-east1, worker-west3, mgmt │
│      → detects preemption (Requeued=True), new inference pods  │
│      → kubectl get hpa, training pods                          │
│                                                                 │
│  VipProber (thread)                                             │
│  └── HTTP requests through VIP → tracks which cluster responds │
│                                                                 │
│  RequestCounter (thread)                                        │
│  └── Polls vLLM success counters to estimate RPS               │
│                                                                 │
│  Load Generator (runs inside cluster as a pod)                  │
│  └── Spawned via kubectl run, sends concurrent requests to VIP │
│      from within the target cluster (geographic affinity)      │
└─────────────────────────────────────────────────────────────────┘
```

### Modes

| Mode | What it does |
|---|---|
| `--mode both` (default) | Runs the load generator pod + live dashboard |
| `--mode dashboard` | Dashboard only — monitor without generating load |
| `--mode load` | Load only — periodic text stats, no Rich UI |

### Load Generation

The script creates a pod (`kv-load-gen`) inside the target cluster using `kubectl run`. The pod runs a Python one-liner that sends concurrent HTTP requests to the gateway VIP from within the cluster. Each request includes a unique 48-character random prefix (`[REQID:...]`) to prevent KV-cache block reuse between requests — every request forces fresh block allocation, which is what fills the cache.

The load pod runs inside the cluster (not locally) so that GCLB's geographic affinity routes requests to the nearest cluster, which is the target cluster itself.

### Metrics Collection

`MetricsCollector` threads run `kubectl exec` into each vLLM pod every 2 seconds and parse the Prometheus `/metrics` endpoint. Extracted metrics:

- `vllm:gpu_cache_usage_perc` — KV cache utilization (0.0–1.0)
- `vllm:num_requests_running` — in-flight requests
- `vllm:num_requests_waiting` — queued requests

### Kueue Event Detection

`KueueCollector` polls three kubectl contexts every ~5 seconds:

- **Worker clusters** (`worker-east1`, `worker-west3`): Gets all Kueue workloads to populate the dashboard table and detect new inference pods
- **Management cluster** (`mgmt`): Gets training workload conditions — specifically the `Requeued` flag, which is the stable signal for preemption (the `Evicted` flag is transient and unreliable to poll)

Events detected:
- **NEW**: A previously unseen inference workload appears on a worker
- **PREEMPTED**: A training workload's `Requeued` condition becomes `True` on mgmt
- **RESCHEDULED**: The preempted training workload appears on a different worker cluster

### Dashboard

The Rich terminal UI is a fixed layout with four sections:

1. **Cluster panels** (left/right) — Per-pod KV cache utilization bars, running/waiting counts, sparkline history
2. **Routing panel** — Target vs spillover cluster, threshold status, VIP probe results
3. **Kueue panel** — HPA status, workload table (cluster/name/type/status/GPUs), training pod counts, timestamped event log
4. **Stats panel** — Load target, concurrency, success/error counts, RPS

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

- **Load runs inside the cluster**: The load generator pod runs within the target worker cluster so GCLB's geographic affinity sends traffic to that cluster first. Running locally would bypass this behavior.
- **Unique prompts per request**: Each request has a random prefix to prevent prefix-cache reuse, ensuring every request allocates fresh KV-cache blocks.
- **Mgmt cluster for preemption detection**: Worker workloads just disappear when preempted. The management cluster's `Requeued=True` condition is the only reliable, sticky signal.
- **Screen-mode Rich layout**: Uses `Live(screen=True)` for a full-terminal dashboard that updates in place without scrolling.
