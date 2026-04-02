#!/usr/bin/env python3
"""
load_test.py — KV-Cache Spillover & Kueue Preemption Demo

Saturates east1's KV cache past the 60% GCPBackendPolicy threshold,
then watches live as the multi-cluster LB shifts traffic to west3.
Also monitors Kueue workloads on west3 — shows training jobs being
preempted as inference scales out to claim GPU capacity.

Usage:
    python3 load_test.py [--mode dashboard|load|both] [--vip IP] [--concurrency N] [--max-tokens N]

Requirements:
    pip install rich
    kubectl contexts: worker-east1, worker-west3
"""

import argparse
import json
import re
import signal
import subprocess
import sys
import textwrap
import threading
import time
import urllib.request
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

from rich import box
from rich.console import Console
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.text import Text

# ── Defaults ───────────────────────────────────────────────────────────────────
DEFAULT_VIP         = ""              # auto-discovered from gateway if not specified
DEFAULT_CONCURRENCY = 300         # workers; each generates unique prompts to avoid prefix-cache reuse
DEFAULT_MAX_TOKENS  = 2048        # long enough to keep requests in-flight and fill KV blocks
KV_THRESHOLD        = 0.60        # must match GCPBackendPolicy maxUtilizationPercent (60%)
METRICS_INTERVAL    = 2.0         # seconds between metric scrapes
PROBE_CONCURRENCY   = 8           # parallel probe workers from local machine through single VIP

LOAD_NAMESPACE  = "inference-server"

# No shared PROMPT_BASE — each request is fully unique so no prefix-cache blocks
# are shared between concurrent requests, forcing real KV-cache block allocation.

CLUSTER_CONFIGS = {
    "us-east1": {"context": "worker-east1", "namespace": "inference-server",
                 "color": "red",  "label": "🔴 us-east1"},
    "us-west3": {"context": "worker-west3", "namespace": "inference-server",
                 "color": "blue", "label": "🔵 us-west3"},
}

MGMT_CONTEXT = "mgmt"


# ── Data classes ───────────────────────────────────────────────────────────────

@dataclass
class PodMetrics:
    pod: str
    cluster: str
    kv_pct: float = 0.0
    running: int = 0
    waiting: int = 0
    success_total: float = 0.0
    error: str = ""
    ts: float = field(default_factory=time.time)


@dataclass
class ClusterMetrics:
    name: str
    pods: List[PodMetrics] = field(default_factory=list)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    @property
    def avg_kv(self) -> float:
        with self._lock:
            vals = [p.kv_pct for p in self.pods if not p.error]
        return (sum(vals) / len(vals)) if vals else 0.0

    @property
    def total_running(self) -> int:
        with self._lock:
            return sum(p.running for p in self.pods)

    @property
    def total_waiting(self) -> int:
        with self._lock:
            return sum(p.waiting for p in self.pods)

    def update(self, new_pods: List[PodMetrics]):
        with self._lock:
            self.pods = new_pods


@dataclass
class LoadStats:
    sent: int = 0
    success: int = 0
    errors: int = 0
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)
    _t0: float = field(default_factory=time.time, repr=False)

    def inc_sent(self):
        with self._lock: self.sent += 1

    def inc_success(self):
        with self._lock: self.success += 1

    def inc_error(self):
        with self._lock: self.errors += 1

    @property
    def rps(self) -> float:
        elapsed = time.time() - self._t0
        return self.success / elapsed if elapsed > 0 else 0.0


@dataclass
class ProbeStats:
    """Tracks probe requests sent through the VIP.
    Monitors the spill cluster's request counter delta to detect spillover.
    """
    total_sent: int = 0
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)
    spill_baseline: float = 0.0
    spill_current: float = 0.0

    def inc(self):
        with self._lock:
            self.total_sent += 1

    @property
    def spill_received(self) -> int:
        return max(0, int(self.spill_current - self.spill_baseline))


@dataclass
class KueueWorkload:
    name: str
    namespace: str
    queue: str
    priority: str
    admitted: bool
    evicted: bool
    phase: str       # "Running", "Admitted", "Pending", "Evicted", "Preempted"
    gpu_count: int
    cluster: str = ""


@dataclass
class KueueState:
    workloads: List[KueueWorkload] = field(default_factory=list)
    training_pods: List[dict] = field(default_factory=list)   # {name, status, node, gpu}
    hpa_replicas: Dict[str, Tuple[int, int, int]] = field(default_factory=dict)  # cluster -> (current, desired, max)
    events: List[str] = field(default_factory=list)  # recent preemption/scale events
    _start_time: float = field(default_factory=time.time)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    def update(self, workloads=None, training_pods=None, hpa_replicas=None):
        with self._lock:
            if workloads is not None:
                self.workloads = workloads
            if training_pods is not None:
                self.training_pods = training_pods
            if hpa_replicas is not None:
                self.hpa_replicas = hpa_replicas

    def add_event(self, msg: str):
        with self._lock:
            ts = time.strftime("%H:%M:%S")
            elapsed = int(time.time() - self._start_time)
            mm, ss = divmod(elapsed, 60)
            if mm > 0:
                rel = f"{mm}m {ss}s into load test"
            else:
                rel = f"{ss}s into load test"
            self.events.append(f"[{ts} · {rel}] {msg}")
            if len(self.events) > 8:
                self.events.pop(0)


class KueueCollector(threading.Thread):
    """Polls Kueue workloads, training pods, and HPA status on west3."""
    def __init__(self, kueue_state: KueueState):
        super().__init__(daemon=True)
        self.state = kueue_state
        self._stop = threading.Event()
        self._prev_workloads: set = set()                # {(name, cluster)} for inference workloads
        self._prev_mgmt_training: Dict[str, dict] = {}   # mgmt workload name -> {evicted, requeued, admitted}
        self._training_cluster_map: Dict[str, str] = {}   # workload name -> cluster label (for preemption messages)
        self._pending_reschedules: set = set()             # workloads preempted but not yet placed on a worker

    def stop(self):
        self._stop.set()

    def _parse_workloads(self, raw: str, cluster: str) -> List[KueueWorkload]:
        workloads = []
        for line in raw.strip().splitlines():
            parts = line.split("|")
            if len(parts) < 8:
                continue
            name, ns, queue, pclass, cq, conds_raw, replicas_raw, gpu_per_replica_raw = (
                parts[0], parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7]
            )
            conds = {}
            for c in conds_raw.split(","):
                if "=" in c:
                    k, v = c.split("=", 1)
                    conds[k] = v

            admitted = conds.get("Admitted") == "True"
            evicted = conds.get("Evicted") == "True"
            if evicted:
                phase = "Evicted"
            elif admitted:
                phase = "Admitted"
            elif conds.get("QuotaReserved") == "True":
                phase = "Reserved"
            else:
                phase = "Pending"

            try:
                replicas = int(replicas_raw.strip() or "1")
            except ValueError:
                replicas = 1
            try:
                gpus_per_replica = int(gpu_per_replica_raw.strip() or "1")
            except ValueError:
                gpus_per_replica = 1
            gpu_count = replicas * gpus_per_replica

            # Skip finished workloads — unless evicted (keep visible for demo)
            finished = conds.get("Finished") == "True"
            if finished and not evicted:
                continue

            wl = KueueWorkload(
                name=name[:50], namespace=ns, queue=queue,
                priority=pclass, admitted=admitted, evicted=evicted,
                phase=phase, gpu_count=gpu_count,
            )
            wl.cluster = cluster
            workloads.append(wl)
        return workloads

    def _get_workloads(self) -> List[KueueWorkload]:
        jsonpath = (
            "jsonpath={range .items[*]}{.metadata.name}|{.metadata.namespace}|"
            "{.metadata.labels.kueue\\.x-k8s\\.io/queue-name}|"
            "{.metadata.labels.kueue\\.x-k8s\\.io/priority-class}|"
            "{.status.admission.clusterQueue}|"
            "{range .status.conditions[*]}{.type}={.status},{end}|"
            "{.spec.podSets[0].count}|"
            "{.spec.podSets[0].template.spec.containers[0].resources.requests.nvidia\\.com/gpu}"
            "{\"\\n\"}{end}"
        )
        all_workloads = []
        for cname, cfg in CLUSTER_CONFIGS.items():
            out, rc = kubectl(
                "get", "workloads", "-A", "-o", jsonpath,
                context=cfg["context"], timeout=10,
            )
            if rc == 0 and out:
                all_workloads.extend(self._parse_workloads(out, cname))
        return all_workloads

    def _get_training_pods(self) -> List[dict]:
        all_pods = []
        for cname, cfg in CLUSTER_CONFIGS.items():
            out, rc = kubectl(
                "get", "pods", "-n", "training-jobs",
                "-o", "jsonpath={range .items[*]}{.metadata.name}|{.status.phase}|"
                "{.spec.nodeName}|{.spec.containers[0].resources.requests.nvidia\\.com/gpu}"
                "{\"\\n\"}{end}",
                context=cfg["context"], timeout=10,
            )
            if rc != 0 or not out:
                continue
            for line in out.strip().splitlines():
                parts = line.split("|")
                if len(parts) < 4:
                    continue
                all_pods.append({
                    "name": parts[0],
                    "status": parts[1],
                    "cluster": cname,
                    "gpu": parts[3] or "1",
                })
        return all_pods

    def _get_hpa(self) -> Dict[str, Tuple]:
        """Returns {cluster: (current, desired, max, metric_value, metric_target)}"""
        result = {}
        for cname, cfg in CLUSTER_CONFIGS.items():
            out, rc = kubectl(
                "get", "hpa", "vllm-inference-hpa", "-n", "inference-server",
                "-o", "jsonpath={.status.currentReplicas}|{.status.desiredReplicas}|"
                "{.spec.maxReplicas}|"
                "{.status.currentMetrics[0].pods.current.averageValue}|"
                "{.spec.metrics[0].pods.target.averageValue}",
                context=cfg["context"], timeout=10,
            )
            if rc == 0 and out:
                parts = out.split("|")
                try:
                    cur = int(parts[0] or 0)
                    desired = int(parts[1] or 0)
                    mx = int(parts[2] or 6)
                    metric_val = parts[3] if len(parts) > 3 else ""
                    metric_target = parts[4] if len(parts) > 4 else ""
                    result[cname] = (cur, desired, mx, metric_val, metric_target)
                except (ValueError, IndexError):
                    pass
        return result

    def _get_mgmt_training_status(self) -> Dict[str, dict]:
        """Poll mgmt cluster for training workload conditions (Evicted, Requeued).

        Returns {workload_name: {evicted: bool, requeued: bool, admitted: bool, cluster: str}}.
        The mgmt cluster is the source of truth for preemption — worker workloads
        just disappear, but mgmt tracks Evicted/Requeued conditions.
        """
        jsonpath = (
            "jsonpath={range .items[*]}{.metadata.name}|"
            "{range .status.conditions[*]}{.type}={.status},{end}|"
            "{.status.admission.clusterQueue}"
            "{\"\\n\"}{end}"
        )
        out, rc = kubectl(
            "get", "workloads", "-n", "training-jobs", "-o", jsonpath,
            context=MGMT_CONTEXT, timeout=10,
        )
        result = {}
        if rc != 0 or not out:
            return result
        for line in out.strip().splitlines():
            parts = line.split("|")
            if len(parts) < 2:
                continue
            name = parts[0]
            conds = {}
            for c in parts[1].split(","):
                if "=" in c:
                    k, v = c.split("=", 1)
                    conds[k] = v
            result[name] = {
                "evicted": conds.get("Evicted") == "True",
                "requeued": conds.get("Requeued") == "True",
                "admitted": conds.get("Admitted") == "True",
            }
        return result

    def _detect_events(self, new_workloads: List[KueueWorkload]):
        # ── Inference events: detect new pods on worker clusters ──
        new_inf_keys = set()
        for wl in new_workloads:
            if wl.namespace == "inference-server":
                key = (wl.name, wl.cluster)
                new_inf_keys.add(key)
                if key not in self._prev_workloads:
                    evt = f"NEW: inference pod admitted on {wl.cluster.replace('us-', '')}"
                    self.state.add_event(evt)
                    with open("/tmp/kueue_events_debug.log", "a") as dbg:
                        dbg.write(f"  >>> EVENT FIRED: {evt}\n")

        # ── Training events: use mgmt as source of truth ──
        # Kueue sets Evicted=True briefly then flips to Evicted=False,Requeued=True
        # after rescheduling. The Evicted=True window is too short to catch reliably.
        # Requeued=True is sticky — use it to detect both preemption and rescheduling.
        mgmt_status = self._get_mgmt_training_status()
        with open("/tmp/kueue_events_debug.log", "a") as dbg:
            dbg.write(f"\n--- {time.strftime('%Y-%m-%dT%H:%M:%S')} ---\n")
            dbg.write(f"mgmt_status: {mgmt_status}\n")
            dbg.write(f"prev_mgmt:   {self._prev_mgmt_training}\n")
            dbg.write(f"cluster_map: {self._training_cluster_map}\n")
            dbg.write(f"pending_reschedules: {self._pending_reschedules}\n")
            dbg.write(f"inf_prev_count: {len(self._prev_workloads)}\n")
            for n, s in mgmt_status.items():
                p = self._prev_mgmt_training.get(n, {})
                dbg.write(f"  {n}: requeued={s.get('requeued')} was_requeued={p.get('requeued', False)}"
                          f" evicted={s.get('evicted')} admitted={s.get('admitted')}\n")
            new_inf = [(wl.name, wl.cluster) for wl in new_workloads if wl.namespace == "inference-server"]
            new_train = [(wl.name, wl.cluster) for wl in new_workloads if wl.namespace == "training-jobs"]
            dbg.write(f"  inference_workloads({len(new_inf)}): {new_inf}\n")
            dbg.write(f"  training_workloads({len(new_train)}): {new_train}\n")
        for name, status in mgmt_status.items():
            prev = self._prev_mgmt_training.get(name, {})
            was_requeued = prev.get("requeued", False)

            if status["requeued"] and not was_requeued:
                short_name = name[:50]
                # Where was this job before preemption?
                old_cluster = self._training_cluster_map.get(short_name, "?")
                evt1 = f"PREEMPTED: {short_name} evicted on {old_cluster}"
                self.state.add_event(evt1)

                # Where did it get rescheduled to?
                new_cluster = None
                for wl in new_workloads:
                    if wl.namespace == "training-jobs" and wl.name == short_name:
                        new_cluster = wl.cluster.replace("us-", "")
                        break
                # Track for deferred RESCHEDULED event if not placed yet
                if new_cluster:
                    evt2 = f"RESCHEDULED: {short_name} → {new_cluster}"
                    self.state.add_event(evt2)
                else:
                    evt2 = f"(pending placement for {short_name})"
                    self._pending_reschedules.add(short_name)

                with open("/tmp/kueue_events_debug.log", "a") as dbg:
                    dbg.write(f"  >>> EVENT FIRED: {evt1}\n")
                    dbg.write(f"  >>> EVENT FIRED: {evt2}\n")
                    dbg.write(f"  >>> events list now: {self.state.events}\n")

        # Check if any pending reschedules have landed on a worker
        if self._pending_reschedules:
            for wl in new_workloads:
                if wl.namespace == "training-jobs" and wl.name in self._pending_reschedules:
                    new_cluster = wl.cluster.replace("us-", "")
                    self.state.add_event(f"RESCHEDULED: {wl.name} → {new_cluster}")
                    self._pending_reschedules.discard(wl.name)

        # Track which cluster each training job is on (for preemption messages).
        # Only update if we haven't just processed a requeue for this job —
        # otherwise the map already has the NEW location before we emit PREEMPTED.
        requeued_this_poll = set()
        for name, status in mgmt_status.items():
            prev = self._prev_mgmt_training.get(name, {})
            if status.get("requeued") and not prev.get("requeued", False):
                requeued_this_poll.add(name[:50])
        for wl in new_workloads:
            if wl.namespace == "training-jobs" and wl.name not in requeued_this_poll:
                self._training_cluster_map[wl.name] = wl.cluster.replace("us-", "")

        self._prev_mgmt_training = mgmt_status
        self._prev_workloads = {
            (wl.name, wl.cluster) for wl in new_workloads
            if wl.namespace == "inference-server"
        }

    def run(self):
        # Truncate debug log at start of each run
        open("/tmp/kueue_events_debug.log", "w").close()
        # Seed with current state so pre-existing workloads don't trigger events
        initial = self._get_workloads()
        self._prev_workloads = {
            (wl.name, wl.cluster) for wl in initial
            if wl.namespace == "inference-server"
        }
        # Seed mgmt training status but mark all as not-yet-requeued so we catch
        # preemptions that happened between load test start and first dashboard poll.
        mgmt_seed = self._get_mgmt_training_status()
        self._prev_mgmt_training = {
            name: {**status, "requeued": False}
            for name, status in mgmt_seed.items()
        }
        for wl in initial:
            if wl.namespace == "training-jobs":
                self._training_cluster_map[wl.name] = wl.cluster.replace("us-", "")
        self.state.update(workloads=initial, training_pods=self._get_training_pods(), hpa_replicas=self._get_hpa())

        while not self._stop.wait(METRICS_INTERVAL + 1):
            workloads = self._get_workloads()
            training_pods = self._get_training_pods()
            hpa = self._get_hpa()
            self._detect_events(workloads)
            self.state.update(workloads=workloads, training_pods=training_pods, hpa_replicas=hpa)


class VipProber(threading.Thread):
    """
    Sends lightweight probe requests through the VIP.
    Tracks the spill cluster's request counter delta to detect spillover.
    """
    def __init__(self, clusters: Dict[str, "ClusterMetrics"],
                 probe_stats: ProbeStats,
                 spill_cluster: str,
                 vip: str = DEFAULT_VIP):
        super().__init__(daemon=True)
        self.clusters = clusters
        self.probe_stats = probe_stats
        self.spill_cluster = spill_cluster
        self.vip = vip
        self._stop = threading.Event()

    def stop(self):
        self._stop.set()

    def _send_probe(self):
        url = f"http://{self.vip}/v1/completions"
        body = json.dumps({
            "model": "meta-llama/Llama-3.1-8B-Instruct",
            "prompt": "Briefly explain KV cache.",
            "max_tokens": 20,
        }).encode()
        try:
            req = urllib.request.Request(
                url, data=body, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=15):
                self.probe_stats.inc()
        except Exception:
            pass

    def _refresh_spill_counter(self):
        """Poll spill cluster's pod success counters to measure spillover."""
        spill_cm = self.clusters.get(self.spill_cluster)
        if not spill_cm:
            return
        total = 0.0
        with spill_cm._lock:
            for p in spill_cm.pods:
                total += p.success_total
        self.probe_stats.spill_current = total

    def run(self):
        self._refresh_spill_counter()
        self.probe_stats.spill_baseline = self.probe_stats.spill_current

        while not self._stop.is_set():
            workers = []
            for _ in range(PROBE_CONCURRENCY):
                t = threading.Thread(target=self._send_probe, daemon=True)
                t.start()
                workers.append(t)
            for t in workers:
                t.join(timeout=20)
            self._refresh_spill_counter()
            time.sleep(0.5)


# ── Kubernetes helpers ─────────────────────────────────────────────────────────

def kubectl(*args, context: str = "", timeout: int = 15) -> Tuple[str, int]:
    cmd = ["kubectl"]
    if context:
        cmd += ["--context", context]
    cmd += list(args)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return (r.stdout + r.stderr).strip(), r.returncode
    except subprocess.TimeoutExpired:
        return "timeout", 1
    except Exception as e:
        return str(e), 1


def discover_gateway_vips() -> Dict[str, str]:
    """Discover per-region VIPs from the cross-region gateway on the mgmt cluster.

    Returns {"us-east1": "10.x.x.x", "us-west3": "10.x.x.x", ...}.
    The gateway spec addresses contain region info in the type field, and
    status addresses are assigned IPs in the same order.
    """
    out, rc = kubectl(
        "get", "gateway", "cross-region-gateway", "-n", "gateway-system",
        "-o", "json", context=MGMT_CONTEXT, timeout=10,
    )
    if rc != 0:
        return {}
    try:
        gw = json.loads(out)
        spec_addrs = gw.get("spec", {}).get("addresses", [])
        status_addrs = gw.get("status", {}).get("addresses", [])
        vips = {}
        for i, sa in enumerate(spec_addrs):
            # type is like "networking.gke.io/ephemeral-ipv4-address/us-east1"
            region = sa.get("type", "").rsplit("/", 1)[-1]
            if i < len(status_addrs) and region:
                vips[region] = status_addrs[i].get("value", "")
        return vips
    except (json.JSONDecodeError, KeyError, IndexError):
        return {}


def get_vllm_pods(context: str, namespace: str) -> List[str]:
    """Return only pods where the vllm container is Ready (serving metrics)."""
    out, rc = kubectl(
        "get", "pods", "-n", namespace,
        "-l", "app=vllm-llama3-8b-instruct",
        "--field-selector=status.phase=Running",
        "-o", "jsonpath={range .items[*]}{.metadata.name}={range .status.containerStatuses[*]}"
        "{.name}:{.ready},{end}|{end}",
        context=context,
    )
    if rc != 0 or not out:
        return []
    ready_pods = []
    for entry in out.split("|"):
        entry = entry.strip()
        if not entry or "=" not in entry:
            continue
        pod_name, container_info = entry.split("=", 1)
        # Check if the vllm container is ready
        for cs in container_info.split(","):
            if cs.startswith("vllm:true"):
                ready_pods.append(pod_name)
                break
    return ready_pods


def parse_prom(text: str, metric: str) -> Optional[float]:
    """Sum all values for a Prometheus metric (handles multiple label sets)."""
    total: Optional[float] = None
    for line in text.splitlines():
        if line.startswith(metric) and not line.startswith("#"):
            try:
                val = float(line.split()[-1])
                total = (total or 0.0) + val
            except ValueError:
                pass
    return total


def scrape_pod(context: str, namespace: str, pod: str) -> dict:
    out, rc = kubectl(
        "exec", "-n", namespace, pod, "--",
        "curl", "-s", "--max-time", "5", "http://localhost:8000/metrics",
        context=context, timeout=10,
    )
    if rc != 0:
        return {"error": (out[:60] if out else "no response")}

    kv = parse_prom(out, "vllm:kv_cache_usage_perc")
    if kv is None:
        kv = parse_prom(out, "vllm:gpu_cache_usage_perc")

    return {
        "kv_pct":        kv if kv is not None else 0.0,
        "running":       int(parse_prom(out, "vllm:num_requests_running") or 0),
        "waiting":       int(parse_prom(out, "vllm:num_requests_waiting") or 0),
        "success_total": parse_prom(out, "vllm:request_success_total") or 0.0,
    }


# ── Load generator pod ─────────────────────────────────────────────────────────

# Minimal Python load-gen script injected via `kubectl exec python3 -c ...`
# We run it once as a background process inside the pod.
# Each request starts with a unique random prefix so prefix-cache blocks are
# never shared — every request forces real KV-cache block allocation.
_LOADER_SCRIPT = textwrap.dedent("""
import asyncio, json, sys, random, string, itertools

TARGETS    = sys.argv[1].split(",")
WORKERS    = int(sys.argv[2])
MAX_TOKENS = int(sys.argv[3])
URLS       = [f"http://{t}/v1/completions" for t in TARGETS]
_url_iter  = itertools.cycle(URLS)
_url_idx   = 0

TOPICS = [
    "distributed GPU memory allocation and KV-cache paging",
    "transformer multi-head attention in large language models",
    "CUDA kernel optimization for NVIDIA Blackwell sm_120 architecture",
    "speculative decoding and draft model selection strategies",
    "tensor parallelism and ring-allreduce in multi-GPU inference",
    "continuous batching and iteration-level scheduling in vLLM",
    "FlashAttention v3 tiling algorithms and SRAM utilization",
    "GPTQ, AWQ, and FP8 quantization calibration techniques",
    "prefix caching via radix trie in paged attention systems",
    "pipeline parallelism bubble minimization with micro-batching",
    "KV-cache eviction policies under memory pressure",
    "LoRA adapter hot-swapping without inference interruption",
    "inference gateway load balancing with custom metrics",
    "chunked prefill scheduling for long-context requests",
    "NVIDIA NVLink bandwidth optimization for tensor operations",
]

FILLER = (
    " Provide a comprehensive technical analysis including: architecture "
    "diagrams, algorithmic complexity, memory footprint calculations, "
    "latency-throughput trade-offs, production deployment considerations, "
    "failure modes and mitigations, benchmark comparisons across hardware "
    "generations, code-level implementation details, and future research "
    "directions. Be exhaustive and precise with numerical values."
)

def make_prompt():
    uid = ''.join(random.choices(string.ascii_lowercase + string.digits, k=48))
    topic = random.choice(TOPICS)
    return f"[REQID:{uid}] Write a detailed 2500-word essay on {topic}.{FILLER}"

async def worker(wid, session):
    # Stagger startup over 5s
    await asyncio.sleep(random.uniform(0, 5))
    url_idx = wid % len(URLS)
    while True:
        tokens = max(256, int(MAX_TOKENS * random.uniform(0.75, 1.25)))
        body = json.dumps({
            "model":      "meta-llama/Llama-3.1-8B-Instruct",
            "prompt":     make_prompt(),
            "max_tokens": tokens,
            "stream":     False,
        }).encode()
        url = URLS[url_idx % len(URLS)]
        url_idx += 1
        try:
            async with session.post(url, data=body,
                headers={"Content-Type": "application/json"}) as resp:
                await resp.read()
        except Exception:
            await asyncio.sleep(0.1)

async def main():
    try:
        import aiohttp
    except ImportError:
        import subprocess
        subprocess.check_call([sys.executable, "-m", "pip", "install",
                               "-q", "aiohttp"], stdout=subprocess.DEVNULL)
        import aiohttp

    conn = aiohttp.TCPConnector(limit=0, ttl_dns_cache=300)
    timeout = aiohttp.ClientTimeout(total=300)
    async with aiohttp.ClientSession(connector=conn, timeout=timeout) as session:
        tasks = [asyncio.create_task(worker(i, session)) for i in range(WORKERS)]
        await asyncio.gather(*tasks)

asyncio.run(main())
""").strip()


def ensure_load_pod(context: str, namespace: str, pod_name: str,
                    console: Console) -> bool:
    """Create/reuse a python:3.11-slim pod for load generation."""
    out, _ = kubectl("get", "pod", pod_name, "-n", namespace,
                     "-o", "jsonpath={.status.phase}", context=context)
    if out == "Running":
        console.log(f"[dim]Reusing existing load pod [bold]{pod_name}[/bold][/dim]")
        return True

    console.log(f"[dim]Creating load pod [bold]{pod_name}[/bold]…[/dim]")
    kubectl("delete", "pod", pod_name, "-n", namespace,
            "--ignore-not-found", "--wait=false", context=context)
    time.sleep(1)

    overrides = json.dumps({
        "spec": {"containers": [{
            "name": pod_name,
            "image": "python:3.11-slim",
            "command": ["sleep", "3600"],
            "resources": {
                "requests": {"cpu": "2", "memory": "2Gi"},
                "limits": {"cpu": "4", "memory": "4Gi"},
            },
        }]},
    })
    _, rc = kubectl(
        "run", pod_name,
        "--image=python:3.11-slim",
        "-n", namespace,
        "--restart=Never",
        f"--overrides={overrides}",
        "--command", "--",
        "sleep", "3600",
        context=context,
    )
    if rc != 0:
        return False

    for _ in range(30):
        out, rc = kubectl("get", "pod", pod_name, "-n", namespace,
                          "-o", "jsonpath={.status.phase}", context=context)
        if rc == 0 and out == "Running":
            console.log(f"[green]Load pod ready[/green]")
            return True
        time.sleep(2)
    return False


def ensure_load_pods(context: str, namespace: str, base_name: str,
                     count: int, console: Console) -> List[str]:
    """Create multiple load pods, return list of ready pod names."""
    ready = []
    for i in range(count):
        name = f"{base_name}-{i}"
        if ensure_load_pod(context, namespace, name, console):
            ready.append(name)
    return ready


def launch_load_in_pod(context: str, namespace: str, pod_name: str,
                       vip: str, concurrency: int, max_tokens: int,
                       console: Console) -> subprocess.Popen:
    """Start the loader script inside the pod as a background Popen process."""
    console.log(
        f"[green]Launching {concurrency} workers inside pod "
        f"[bold]{pod_name}[/bold] → [bold]{vip}[/bold][/green]"
    )
    cmd = [
        "kubectl", "--context", context,
        "exec", "-n", namespace, pod_name, "--",
        "python3", "-c", _LOADER_SCRIPT,
        vip, str(concurrency), str(max_tokens),
    ]
    return subprocess.Popen(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def launch_load_in_pods(context: str, namespace: str, pod_names: List[str],
                        vip: str, concurrency: int, max_tokens: int,
                        console: Console) -> List[subprocess.Popen]:
    """Split concurrency across multiple load pods and launch them all."""
    per_pod = concurrency // len(pod_names)
    remainder = concurrency % len(pod_names)
    procs = []
    for i, name in enumerate(pod_names):
        c = per_pod + (1 if i < remainder else 0)
        procs.append(launch_load_in_pod(context, namespace, name,
                                        vip, c, max_tokens, console))
    return procs


# ── Metrics collection thread ──────────────────────────────────────────────────

class MetricsCollector(threading.Thread):
    def __init__(self, clusters: Dict[str, ClusterMetrics]):
        super().__init__(daemon=True)
        self.clusters = clusters
        self._stop = threading.Event()

    def stop(self):
        self._stop.set()

    def run(self):
        while not self._stop.wait(METRICS_INTERVAL):
            for cname, cfg in CLUSTER_CONFIGS.items():
                cm = self.clusters[cname]
                pods = get_vllm_pods(cfg["context"], cfg["namespace"])
                new_pods = []
                # Scrape pods in parallel
                results: Dict[str, dict] = {}
                threads = []
                for pod in pods:
                    def _scrape(p=pod, c=cfg):
                        results[p] = scrape_pod(c["context"], c["namespace"], p)
                    t = threading.Thread(target=_scrape, daemon=True)
                    t.start()
                    threads.append(t)
                for t in threads:
                    t.join(timeout=12)
                for pod in pods:
                    m = results.get(pod, {"error": "no result"})
                    new_pods.append(PodMetrics(
                        pod=pod, cluster=cname,
                        kv_pct=m.get("kv_pct", 0.0),
                        running=m.get("running", 0),
                        waiting=m.get("waiting", 0),
                        success_total=m.get("success_total", 0.0),
                        error=m.get("error", ""),
                    ))
                cm.update(new_pods)


# ── Rich dashboard ─────────────────────────────────────────────────────────────

_HISTORY_LEN = 40  # sparkline width

class Dashboard:
    def __init__(self, clusters: Dict[str, ClusterMetrics],
                 stats: LoadStats, concurrency: int, vip: str,
                 load_target: str = "",
                 probe_stats: Optional[ProbeStats] = None,
                 kueue_state: Optional[KueueState] = None,
                 load_active: bool = True,
                 target_cluster: str = "us-east1",
                 spill_cluster: str = "us-west3"):
        self.clusters   = clusters
        self.stats      = stats
        self.concurrency = concurrency
        self.vip        = vip
        self.load_target = load_target or vip
        self.probe_stats = probe_stats
        self.kueue_state = kueue_state
        self.load_active = load_active
        self.target_cluster = target_cluster
        self.spill_cluster  = spill_cluster
        # Rolling KV history per cluster for the mini sparkline
        self._kv_hist: Dict[str, List[float]] = {c: [] for c in clusters}
        self._last_kv: Dict[str, float] = {c: 0.0 for c in clusters}
        self._kv_rate: Dict[str, float] = {c: 0.0 for c in clusters}  # %/s

    def _update_history(self):
        for cname, cm in self.clusters.items():
            h = self._kv_hist[cname]
            cur = cm.avg_kv
            prev = self._last_kv.get(cname, cur)
            # Smoothed fill-rate in %/s
            raw_rate = (cur - prev) / METRICS_INTERVAL * 100
            self._kv_rate[cname] = raw_rate if raw_rate > 0 else 0.0
            self._last_kv[cname] = cur
            h.append(cur)
            if len(h) > _HISTORY_LEN:
                h.pop(0)

    @staticmethod
    def _kv_bar(pct: float, width: int = 28) -> Text:
        filled = int(pct * width)
        bar = "█" * filled + "░" * (width - filled)
        if pct >= KV_THRESHOLD:
            style = "bold red"
        elif pct >= KV_THRESHOLD * 0.8:
            style = "yellow"
        else:
            style = "green"
        t = Text()
        t.append(bar, style=style)
        t.append(f"  {pct * 100:5.1f}%", style=style)
        return t

    @staticmethod
    def _sparkline(history: List[float]) -> Text:
        """Single-row Unicode sparkline of KV utilisation history."""
        blocks = " ▁▂▃▄▅▆▇█"
        t = Text(style="dim")
        for v in history:
            idx = min(int(v * (len(blocks) - 1)), len(blocks) - 1)
            color = "green" if v < 0.5 else ("yellow" if v < KV_THRESHOLD else "red")
            t.append(blocks[idx], style=color)
        return t

    def _cluster_panel(self, cname: str) -> Panel:
        cm   = self.clusters[cname]
        cfg  = CLUSTER_CONFIGS[cname]
        avg  = cm.avg_kv
        hist = self._kv_hist[cname]

        rows: List[Tuple] = []
        with cm._lock:
            pods = list(cm.pods)

        for p in pods:
            # Skip pods with scrape errors — they're likely still initializing
            if p.error:
                continue
            # Strip the common deployment prefix to fit
            short = re.sub(r'^vllm-llama3-8b-instruct-', 'vllm-', p.pod)
            if len(short) > 18:
                short = "…" + short[-17:]
            rows.append((short, self._kv_bar(p.kv_pct),
                          str(p.running), str(p.waiting)))

        if not rows:
            n_total = len(pods)
            if n_total > 0:
                rows.append((f"[dim]{n_total} pod(s) starting…[/dim]", Text(""), "", ""))
            else:
                rows.append(("[dim]no pods[/dim]", Text(""), "", ""))

        from rich.table import Table
        tbl = Table(box=box.SIMPLE, expand=True, show_header=True,
                    header_style="bold dim", padding=(0, 1))
        tbl.add_column("Pod",      no_wrap=True, max_width=18)
        tbl.add_column("KV Cache", min_width=36, no_wrap=True)
        tbl.add_column("Run",  justify="right", width=4)
        tbl.add_column("Wait", justify="right", width=4)
        for row in rows:
            tbl.add_row(*row)

        # Sparkline row
        spark = self._sparkline(hist)
        spark_line = Text("  history  ") + spark if hist else Text("")

        from rich.console import Group
        body = Group(tbl, spark_line)

        avg_style = "bold red" if avg >= KV_THRESHOLD else (
            "yellow" if avg >= KV_THRESHOLD * 0.8 else "green"
        )
        rate = self._kv_rate.get(cname, 0.0)
        rate_str = f"+{rate:.2f}%/s" if rate > 0.01 else "steady"
        title = (
            f"{cfg['label']}  "
            f"[dim]avg KV:[/dim] [{avg_style}]{avg * 100:.1f}%[/{avg_style}]  "
            f"[dim]fill:[/dim] [cyan]{rate_str}[/cyan]  "
            f"[dim]run:[/dim] {cm.total_running}  "
            f"[dim]wait:[/dim] {cm.total_waiting}"
        )
        return Panel(body, title=title, border_style=cfg["color"], expand=True)

    def _routing_panel(self) -> Panel:
        tc = self.target_cluster
        sc = self.spill_cluster
        tc_cfg = CLUSTER_CONFIGS[tc]
        sc_cfg = CLUSTER_CONFIGS[sc]
        tc_label = tc.replace("us-", "")   # e.g. "east1", "west3"
        sc_label = sc.replace("us-", "")

        target_cm = self.clusters[tc]
        spill_cm  = self.clusters[sc]
        t_kv, s_kv = target_cm.avg_kv, spill_cm.avg_kv
        spilling = t_kv >= KV_THRESHOLD
        ps = self.probe_stats

        t = Text()
        t.append(f"\n  {tc_label}  ", style=f"{tc_cfg['color']} bold")
        t.append(self._kv_bar(t_kv, width=30))
        if spilling:
            t.append(f"  ⚠  OVER THRESHOLD\n", style="bold red")
        else:
            t.append(f"  {t_kv*100:.0f}%  below {KV_THRESHOLD*100:.0f}%\n", style="dim")

        t.append(f"  {sc_label}  ", style=f"{sc_cfg['color']} bold")
        t.append(self._kv_bar(s_kv, width=30))

        spill_cnt = ps.spill_received if ps else 0
        total = ps.total_sent if ps else 0

        if ps and spill_cnt > 0:
            t.append(f"  ← receiving spill ({spill_cnt} probes)\n\n", style="bold green")
        else:
            t.append(f"  standby\n\n", style="dim")

        if not ps:
            if spilling:
                t.append(
                    f"  ⚠  {tc_label} KV cache over {KV_THRESHOLD*100:.0f}% threshold  ",
                    style="bold red",
                )
            elif t_kv >= KV_THRESHOLD * 0.75:
                t.append(
                    f"  ⚡  Approaching threshold  ({t_kv*100:.1f}% / {KV_THRESHOLD*100:.0f}%)",
                    style="bold yellow",
                )
            else:
                t.append(
                    f"  ✓  Monitoring  │  VIP: {self.vip}",
                    style="green",
                )
        elif spilling:
            spill_pct = (spill_cnt / total * 100) if total > 0 else 0.0
            t.append(
                f"  ▶  {tc_label} KV cache FULL — GCLB routing probes to {sc_label}  ",
                style="bold black on green",
            )
            t.append(
                f"\n  Probes sent: {total}  →  {sc_label} received: {spill_cnt}  "
                f"({spill_pct:.0f}% spilled)  │  VIP: {self.vip}",
                style="dim",
            )
        elif t_kv >= KV_THRESHOLD * 0.75:
            t.append(
                f"  ⚡  Approaching threshold  ({t_kv*100:.1f}% / {KV_THRESHOLD*100:.0f}%)  "
                f"— spillover imminent",
                style="bold yellow",
            )
        else:
            t.append(
                f"  ✓  All traffic → {tc_label}  ({total} probes via {self.vip})",
                style="green",
            )

        return Panel(t, title=f"Routing Decision  [dim]({tc_label} → {sc_label} spillover)[/dim]",
                     border_style="white", expand=True)

    def _kueue_panel(self) -> Panel:
        ks = self.kueue_state
        if not ks:
            return Panel("[dim]Kueue monitoring disabled[/dim]",
                         title="Kueue", border_style="dim")

        from rich.table import Table
        from rich.console import Group

        # HPA status
        hpa_text = Text()
        hpa_text.append("  HPA  ", style="bold dim")
        with ks._lock:
            for cname in ["us-east1", "us-west3"]:
                cfg = CLUSTER_CONFIGS[cname]
                r = ks.hpa_replicas.get(cname)
                if r:
                    cur, desired, mx = r[:3]
                    metric_val = r[3] if len(r) > 3 else ""
                    metric_target = r[4] if len(r) > 4 else ""
                    scaling = desired > cur
                    replica_style = "bold yellow" if scaling else "green"
                    hpa_text.append(f"  {cfg['label']} ", style=cfg["color"])
                    hpa_text.append(f"{cur}/{mx}", style=replica_style)
                    if scaling:
                        hpa_text.append(f"→{desired}", style="bold yellow")
                    if metric_val and metric_target:
                        # Convert milli-units to percentage (685m → 68.5%)
                        def milli_to_pct(s):
                            s = s.strip()
                            if s.endswith("m"):
                                return float(s[:-1]) / 10.0
                            try:
                                return float(s) * 100.0
                            except ValueError:
                                return 0.0
                        val_pct = milli_to_pct(metric_val)
                        tgt_pct = milli_to_pct(metric_target)
                        over = val_pct > tgt_pct
                        metric_style = "bold red" if over else "dim"
                        hpa_text.append(f" {val_pct:.0f}%/{tgt_pct:.0f}%", style=metric_style)

        # MultiKueue depth — query mgmt cluster for the full queue view
        # Worker clusters only see dispatched workloads; mgmt sees all (pending + admitted)
        depth_text = Text()
        mgmt_wl_out, mgmt_rc = kubectl(
            "get", "workloads", "-n", "training-jobs",
            "-o", "jsonpath={range .items[*]}{.metadata.name}|"
            "{range .status.conditions[*]}{.type}={.status},{end}"
            "{\"\\n\"}{end}",
            context=MGMT_CONTEXT, timeout=10,
        )
        mgmt_jobs = []
        if mgmt_rc == 0 and mgmt_wl_out:
            for line in mgmt_wl_out.strip().splitlines():
                parts = line.split("|")
                if len(parts) < 2:
                    continue
                name = parts[0]
                conds = {}
                for c in parts[1].split(","):
                    if "=" in c:
                        k, v = c.split("=", 1)
                        conds[k] = v
                admitted = conds.get("Admitted") == "True"
                evicted = conds.get("Evicted") == "True"
                finished = conds.get("Finished") == "True"
                if finished and not evicted:
                    continue
                mgmt_jobs.append({"name": name, "admitted": admitted, "evicted": evicted})
        if mgmt_jobs:
            n_admitted = sum(1 for j in mgmt_jobs if j["admitted"] and not j["evicted"])
            n_pending = sum(1 for j in mgmt_jobs if not j["admitted"] and not j["evicted"])
            n_evicted = sum(1 for j in mgmt_jobs if j["evicted"])
            depth_text.append("\n  MultiKueue depth  ", style="bold dim")
            for j in sorted(mgmt_jobs, key=lambda j: (0 if j["admitted"] and not j["evicted"] else 1 if j["evicted"] else 2, j["name"])):
                if j["evicted"]:
                    depth_text.append("█", style="red")
                elif j["admitted"]:
                    depth_text.append("█", style="green")
                else:
                    depth_text.append("█", style="yellow")
            depth_text.append(f"  {len(mgmt_jobs)} jobs", style="dim")
            depth_text.append(f"  [", style="dim")
            depth_text.append(f"█", style="green")
            depth_text.append(f"dispatched ", style="dim")
            depth_text.append(f"█", style="yellow")
            depth_text.append(f"queued", style="dim")
            if n_evicted:
                depth_text.append(f" █", style="red")
                depth_text.append(f"preempted", style="dim")
            depth_text.append(f"]", style="dim")

        # Workloads table
        tbl = Table(box=box.SIMPLE, expand=True, show_header=True,
                    header_style="bold dim", padding=(0, 1))
        tbl.add_column("Cluster", width=7)
        tbl.add_column("Workload", no_wrap=True, max_width=28)
        tbl.add_column("Type", width=10)
        tbl.add_column("Status", width=12)
        tbl.add_column("GPUs", justify="right", width=4)

        with ks._lock:
            workloads = list(ks.workloads)
            events = list(ks.events)
            training_pods = list(ks.training_pods)

        # Sort by cluster, then type (training first so preemption is visible), then name
        for wl in sorted(workloads, key=lambda w: (w.cluster, 0 if w.namespace == "training-jobs" else 1, w.name)):
            if wl.namespace == "inference-server":
                wl_type = "inference"
                type_style = "cyan"
            elif "pre-training" in wl.name:
                wl_type = "pre-training"
                type_style = "red"
            else:
                wl_type = "experiment"
                type_style = "magenta"
            cluster_label = "east1" if "east" in wl.cluster else "west3"
            cluster_style = "red" if "east" in wl.cluster else "blue"

            if wl.phase == "Evicted":
                status_style = "bold red"
                status_text = "PREEMPTED"
            elif wl.phase == "Admitted":
                status_style = "green"
                status_text = "Running"
            elif wl.phase == "Pending":
                status_style = "yellow"
                status_text = "Pending"
            else:
                status_style = "dim"
                status_text = wl.phase

            # Shorten workload names to fit
            short_name = wl.name
            short_name = re.sub(r'^pod-vllm-llama3-8b-instruct-\w+-', 'vllm-', short_name)
            short_name = re.sub(r'^jobset-', '', short_name)

            tbl.add_row(
                Text(cluster_label, style=cluster_style),
                short_name,
                Text(wl_type, style=type_style),
                Text(status_text, style=status_style),
                str(wl.gpu_count),
            )

        if not workloads:
            tbl.add_row("", "[dim]no workloads[/dim]", "", "", "")

        # Training pods summary per cluster
        pods_text = Text()
        if training_pods:
            pods_text.append("  Experiment/Pre-training pods: ", style="dim")
            for cname, clabel, cstyle in [("us-east1", "east1", "red"), ("us-west3", "west3", "blue")]:
                cpods = [p for p in training_pods if p.get("cluster") == cname]
                if not cpods:
                    continue
                crunning = sum(1 for p in cpods if p["status"] == "Running")
                ctotal = len(cpods)
                pods_text.append(f" {clabel} ", style=cstyle)
                pods_text.append(f"{crunning}/{ctotal}", style="green" if crunning == ctotal else "yellow")
                cevicted = ctotal - crunning
                if cevicted > 0:
                    pods_text.append(f" ({cevicted} evicted)", style="bold red")

        # Events log
        events_text = Text()
        # Debug: log what the renderer sees
        with open("/tmp/kueue_events_debug.log", "a") as dbg:
            dbg.write(f"  [RENDER] events count={len(events)}, last4={events[-8:] if events else []}\n")
        if events:
            events_text.append(f"\n  Recent events ({len(events)} total):\n", style="bold dim")
            for ev in events[-8:]:
                if "PREEMPTED" in ev:
                    events_text.append(f"  {ev}\n", style="bold red")
                elif "RESCHEDULED" in ev:
                    events_text.append(f"  {ev}\n", style="bold cyan")
                elif "SCALED" in ev or "NEW" in ev:
                    events_text.append(f"  {ev}\n", style="green")
                else:
                    events_text.append(f"  {ev}\n", style="yellow")

        body = Group(hpa_text, depth_text, tbl, pods_text, events_text)

        # Count GPUs per cluster
        evicted_count = sum(1 for wl in workloads if wl.evicted)
        gpu_parts = []
        for cname, clabel, cstyle in [("us-east1", "east1", "red"), ("us-west3", "west3", "blue")]:
            cwl = [wl for wl in workloads if wl.cluster == cname]
            cinf = sum(wl.gpu_count for wl in cwl if wl.namespace == "inference-server" and wl.admitted)
            cexp = sum(wl.gpu_count for wl in cwl if wl.namespace == "training-jobs" and "pre-training" not in wl.name and wl.admitted)
            cpre = sum(wl.gpu_count for wl in cwl if wl.namespace == "training-jobs" and "pre-training" in wl.name and wl.admitted)
            gpu_parts.append(f"[{cstyle}]{clabel}[/{cstyle}] [dim]inf:[/dim] {cinf}  [dim]exp:[/dim] {cexp}  [dim]pre:[/dim] {cpre}")

        title = (
            f"Kueue Orchestration  [dim]│[/dim]  "
            f"[dim]GPUs[/dim]  {'  [dim]│[/dim]  '.join(gpu_parts)}"
        )
        if evicted_count:
            title += f"  [dim]│[/dim]  [bold red]{evicted_count} preempted[/bold red]"

        return Panel(body, title=title, border_style="magenta", expand=True)

    def _stats_panel(self) -> Panel:
        t = Text()

        # Compute fleet-wide running requests and RPS from pod metrics
        total_running = 0
        total_waiting = 0
        total_success = 0.0
        per_cluster = {}
        for cname, cm in self.clusters.items():
            with cm._lock:
                pods = list(cm.pods)
            c_run = sum(p.running for p in pods)
            c_wait = sum(p.waiting for p in pods)
            c_succ = sum(p.success_total for p in pods)
            total_running += c_run
            total_waiting += c_wait
            total_success += c_succ
            label = cname.replace("us-", "")
            per_cluster[label] = (c_run, c_wait, len(pods))
        fleet_rps = self.stats.rps

        if self.load_active:
            # Internal load generator mode — show load gen stats
            s = self.stats
            is_direct = self.load_target != self.vip
            t.append(f"  Load → ", style="dim")
            if is_direct:
                t.append(f"{self.load_target}", style="yellow")
                t.append(f"  (east1 direct — LB VIP: {self.vip})   ", style="dim")
            else:
                t.append(f"{self.vip}   ", style="dim")
            t.append(f"Concurrency: {self.concurrency}   ", style="cyan")
            t.append(f"Success: {s.success:,}   ", style="green")
            t.append(f"Errors: {s.errors:,}   ",
                     style="bold red" if s.errors else "dim")
            t.append(f"RPS ≈ {s.rps:.1f}", style="yellow")
            if is_direct:
                t.append(
                    f"\n  [dim]Direct load fills east1 KV cache. "
                    f"Once east1 > {KV_THRESHOLD*100:.0f}%, GCP LB routes new VIP "
                    f"traffic to west3 (metric propagation ~10–60 s)[/dim]"
                )
            else:
                t.append(
                    f"\n  [dim]Load via VIP — LB distributes across both regions. "
                    f"Run with --direct-ip 34.118.238.239:8000 to fill east1 first.[/dim]"
                )
        elif total_running > 0:
            # External load detected — show live metrics from pod scraping
            t.append("  External load detected  ", style="bold green")
            t.append(f"VIP: {self.vip}\n", style="dim")
            t.append(f"  Running: ", style="dim")
            t.append(f"{total_running:,}", style="bold cyan")
            t.append(f"  Waiting: ", style="dim")
            t.append(f"{total_waiting:,}", style="yellow" if total_waiting else "dim")
            t.append(f"  RPS ≈ ", style="dim")
            t.append(f"{fleet_rps:.1f}", style="yellow")
            t.append(f"\n  ", style="dim")
            for label, (c_run, c_wait, n_pods) in per_cluster.items():
                style = "red" if label == "east1" else "blue"
                t.append(f"{label}", style=style)
                t.append(f": {c_run} running / {c_wait} waiting ({n_pods} pods)   ", style="dim")
        else:
            # No load
            t.append("  Waiting for load  ", style="dim bold")
            t.append(f"— monitoring {self.vip}  ", style="dim")
            t.append("Metrics are live from cluster pods.", style="dim")

        title = "Load Generator" if self.load_active else "Monitor"
        border = "green" if total_running > 0 else "dim"
        return Panel(t, title=title, border_style=border, expand=True)

    def render(self) -> Layout:
        self._update_history()

        has_kueue = self.kueue_state is not None
        # Size the kueue panel based on workload count:
        # header(2) + table rows + HPA line(1) + training summary(1) + events(~4) + borders(3)
        kueue_rows = 11  # minimum
        if has_kueue and self.kueue_state:
            with self.kueue_state._lock:
                n_wl = len(self.kueue_state.workloads)
                n_ev = len(self.kueue_state.events)
            kueue_rows = max(12, n_wl + max(n_ev, 10) + 15)

        layout = Layout()
        layout.split_column(
            Layout(name="header",   size=3),
            Layout(name="clusters", size=14),
            Layout(name="routing",  size=9),
            *([ Layout(name="kueue") ] if has_kueue else []),  # takes remaining space
            Layout(name="stats",    size=5),
        )
        layout["header"].update(Panel(
            "[bold white]KV-Cache Spillover & Kueue Preemption Demo[/bold white]  "
            "[dim]│  GKE Multi-Cluster Inference Gateway  │  "
            f"Threshold: {KV_THRESHOLD*100:.0f}%  │  "
            "Ctrl-C to stop[/dim]",
        ))
        layout["clusters"].split_row(
            Layout(self._cluster_panel("us-east1"), name="east"),
            Layout(self._cluster_panel("us-west3"), name="west"),
        )
        layout["routing"].update(self._routing_panel())
        if has_kueue:
            layout["kueue"].update(self._kueue_panel())
        layout["stats"].update(self._stats_panel())
        return layout


# ── Request counter thread (polls pod metrics for success delta) ───────────────

class RequestCounter(threading.Thread):
    """
    Approximates load stats from the vLLM success counter on east1,
    since the real load runs inside the cluster pod.
    """
    def __init__(self, stats: LoadStats,
                 clusters: Dict[str, ClusterMetrics]):
        super().__init__(daemon=True)
        self.stats    = stats
        self.clusters = clusters
        self._prev: Dict[str, float] = {}
        self._stop = threading.Event()

    def stop(self): self._stop.set()

    def run(self):
        while not self._stop.wait(METRICS_INTERVAL):
            total_success = 0.0
            for cm in self.clusters.values():
                with cm._lock:
                    for p in cm.pods:
                        total_success += p.success_total

            prev_total = sum(self._prev.values()) if self._prev else total_success
            delta = max(0, total_success - prev_total)

            with self.stats._lock:
                self.stats.success += int(delta)
                self.stats.sent    += int(delta)

            for cm in self.clusters.values():
                with cm._lock:
                    for p in cm.pods:
                        self._prev[p.pod] = p.success_total


# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Live KV-cache spillover demo for GKE multi-cluster inference gateway"
    )
    parser.add_argument("--vip",         default="",
                        help="Load balancer VIP (auto-discovered from gateway if not specified)")
    parser.add_argument("--concurrency", type=int, default=DEFAULT_CONCURRENCY,
                        help=f"Concurrent workers in load pod (default {DEFAULT_CONCURRENCY})")
    parser.add_argument("--max-tokens",  type=int, default=DEFAULT_MAX_TOKENS,
                        help=f"Max tokens per completion (default {DEFAULT_MAX_TOKENS}); "
                             "higher = longer in-flight time = more KV blocks held")
    parser.add_argument("--direct-ip",   default="",
                        help="Target this IP:port directly (e.g. east1 ClusterIP 34.118.238.239:8000) "
                             "to fill east1 KV cache without LB distributing to west3. "
                             "Useful to demonstrate spillover: fill east1 directly, "
                             "then new VIP traffic routes to west3.")
    parser.add_argument("--target-cluster", default="east1", choices=["east1", "west3"],
                        help="Which cluster to run the load generator in and target directly "
                             "(default east1). Use west3 to validate Kueue preemption: "
                             "fills west3 KV cache → HPA scales → preempts training jobs.")
    parser.add_argument("--load-pods", type=int, default=4,
                        help="Number of load generator pods to spread concurrency across (default 4)")
    parser.add_argument("--mode", default="both", choices=["dashboard", "load", "both"],
                        help="dashboard = live UI only (no load generated), "
                             "load = generate load with periodic text stats (no Rich UI), "
                             "both = full experience (default)")
    args = parser.parse_args()

    # Resolve target and spill clusters from --target-cluster flag
    target_cluster = f"us-{args.target_cluster}"  # "us-east1" or "us-west3"
    spill_cluster  = [c for c in CLUSTER_CONFIGS if c != target_cluster][0]

    # Discover VIPs from gateway if not explicitly provided
    if not args.vip:
        vips = discover_gateway_vips()
        if target_cluster in vips:
            args.vip = vips[target_cluster]
        elif vips:
            # Fall back to first available VIP
            args.vip = list(vips.values())[0]
        else:
            print("ERROR: Cannot discover gateway VIPs from mgmt cluster. "
                  "Provide --vip explicitly.", file=sys.stderr)
            sys.exit(1)

    # Load generator runs inside the target cluster for geographic affinity
    load_context = CLUSTER_CONFIGS[target_cluster]["context"]
    load_pod_base = f"kv-load-gen-{args.target_cluster}"

    run_load      = args.mode in ("load", "both")
    run_dashboard = args.mode in ("dashboard", "both")

    console = Console()
    console.print(
        f"\n[bold]KV-Cache Spillover & Kueue Preemption Demo[/bold]  "
        f"mode=[cyan]{args.mode}[/cyan]  "
        f"vip=[cyan]{args.vip}[/cyan]  "
        f"concurrency=[cyan]{args.concurrency}[/cyan]  "
        f"max_tokens=[cyan]{args.max_tokens}[/cyan]  "
        f"target=[cyan]{args.target_cluster}[/cyan]\n"
    )

    # ── Setup load pods (skip in dashboard-only mode) ─────────────────────────
    loader_procs: List[subprocess.Popen] = []
    load_pod_names: List[str] = []
    load_target = args.vip

    if run_load:
        load_pod_names = ensure_load_pods(
            load_context, LOAD_NAMESPACE, load_pod_base,
            args.load_pods, console,
        )
        if not load_pod_names:
            console.print("[bold red]Failed to create load generator pods — aborting[/bold red]")
            sys.exit(1)

        # Determine load target
        if args.direct_ip:
            load_target = args.direct_ip
            console.print(
                f"[yellow]Direct mode:[/yellow] targeting [bold]{load_target}[/bold] "
                f"(bypassing LB to fill KV cache directly)"
            )
        else:
            spill_label = spill_cluster.replace("us-", "")
            console.print(
                f"[green]VIP mode:[/green] load → [bold]{args.vip}[/bold] ({args.target_cluster} VIP) "
                f"→ saturates {args.target_cluster} → GCLB spills to {spill_label}"
            )

        console.print(
            f"[green]Splitting {args.concurrency} workers across "
            f"{len(load_pod_names)} pods[/green]"
        )
        loader_procs = launch_load_in_pods(
            load_context, LOAD_NAMESPACE, load_pod_names,
            load_target, args.concurrency, args.max_tokens, console,
        )

    # ── Init metrics ──────────────────────────────────────────────────────────
    clusters: Dict[str, ClusterMetrics] = {
        name: ClusterMetrics(name=name) for name in CLUSTER_CONFIGS
    }
    stats = LoadStats()
    probe_stats = ProbeStats()
    kueue_state = KueueState()

    collector = MetricsCollector(clusters)
    counter   = RequestCounter(stats, clusters)
    prober    = VipProber(clusters, probe_stats, spill_cluster=spill_cluster) if run_load else None
    kueue_collector = KueueCollector(kueue_state)
    collector.start()
    counter.start()
    if prober:
        prober.start()
    kueue_collector.start()

    dashboard = Dashboard(clusters, stats, args.concurrency, args.vip,
                          load_target=load_target,
                          probe_stats=probe_stats if run_load else None,
                          kueue_state=kueue_state, load_active=run_load,
                          target_cluster=target_cluster,
                          spill_cluster=spill_cluster)

    # ── Cleanup ───────────────────────────────────────────────────────────────
    def shutdown(sig=None, frame=None):
        console.print("\n[yellow]Shutting down…[/yellow]")
        collector.stop()
        counter.stop()
        if prober:
            prober.stop()
        kueue_collector.stop()
        for proc in loader_procs:
            if proc.poll() is None:
                proc.terminate()
        if run_load:
            for pname in load_pod_names:
                kubectl(
                    "delete", "pod", pname, "-n", LOAD_NAMESPACE,
                    "--ignore-not-found", "--wait=false",
                    context=load_context,
                )
        console.print("[green]Done.[/green]")
        sys.exit(0)

    signal.signal(signal.SIGINT,  shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    # ── Live display or text-only stats loop ──────────────────────────────────
    if run_dashboard:
        console.print("[dim]Collecting initial metrics (≈5 s)…[/dim]")
        time.sleep(5)
        with Live(console=console, refresh_per_second=2, screen=True) as live:
            while True:
                live.update(dashboard.render())
                time.sleep(0.5)
    else:
        # Load-only mode: print periodic text stats
        console.print("[dim]Load running — printing stats every 5 s (Ctrl-C to stop)…[/dim]")
        time.sleep(5)
        while True:
            tc_label = target_cluster.replace("us-", "")
            sc_label = spill_cluster.replace("us-", "")
            tc_kv = clusters[target_cluster].avg_kv * 100
            sc_kv = clusters[spill_cluster].avg_kv * 100
            tc_run = clusters[target_cluster].total_running
            sc_run = clusters[spill_cluster].total_running
            console.print(
                f"{tc_label} KV={tc_kv:5.1f}% run={tc_run:3d}  |  "
                f"{sc_label} KV={sc_kv:5.1f}% run={sc_run:3d}  |  "
                f"success={stats.success:,}  errors={stats.errors:,}  "
                f"rps={stats.rps:.1f}"
            )
            time.sleep(5)


if __name__ == "__main__":
    main()
