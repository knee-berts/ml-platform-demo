# Least-Disruption MultiKueue Dispatcher

A custom external dispatcher for [MultiKueue](https://kueue.sigs.k8s.io/docs/concepts/multikueue/) that replaces the default `AllAtOnce` dispatching strategy with an eviction-aware, cost-based scoring model. Instead of sending workloads to all worker clusters simultaneously (causing double-eviction when the losing cluster cancels), this dispatcher scores each cluster and sends the workload to exactly one — the cluster that requires the least disruption.

## Problem

With MultiKueue's default `AllAtOnce` dispatcher, a high-priority workload is dispatched to every worker cluster in parallel. Each cluster preempts lower-priority workloads to make room. The first cluster to admit wins; the others delete their copy. But the evictions on the losing clusters already happened — GPUs were freed, workloads were killed, and recovery takes time. With 2 clusters, every critical job causes 2x the disruption necessary.

## How It Works

The dispatcher runs as a controller on the management cluster. When Kueue reserves quota for a workload but hasn't dispatched it yet, the dispatcher:

1. **Reads cluster state** from local informer caches (no live API calls during reconciliation)
2. **Scores each worker cluster** based on the eviction cost of placing the workload there
3. **Accounts for in-flight dispatches** to prevent the thundering herd problem
4. **Sets `status.nominatedClusterNames`** to the single best cluster
5. MultiKueue's built-in controller then dispatches only to that cluster

## Scoring Algorithm

For each candidate cluster, given an incoming workload requesting N GPUs at priority P:

```
free_gpus = quota - used - in_flight
needed = N - free_gpus

if needed <= 0 → score = 0 (no eviction needed)
else:
    walk admitted workloads from lowest priority upward:
        if workload.priority >= P → stop (can't preempt)
        cost = gpu_count × priority_weight × status_multiplier
        score += cost
        needed -= gpu_count
        if needed <= 0 → return score

    if needed > 0 → infeasible (can't fit)
```

**Priority weights** (configurable via ConfigMap):
- `training-low` (100): weight 1
- `inference-high` (1000): weight 10
- `training-critical` (2000): weight 1000

**Status multiplier**: running workloads cost 2x to preempt vs pending ones.

### Cluster Selection

After scoring, the best cluster is selected using a three-tier tiebreaker:

1. **Lowest eviction score** — prefer the cluster that disrupts the fewest and least important workloads
2. **Highest cluster priority** — from the `dispatcher.kueue.x-k8s.io/priority` label on MultiKueueCluster resources (higher value = preferred)
3. **Most free GPUs** — prefer the cluster with the most available capacity

When no cluster is feasible, the dispatcher leaves `nominatedClusterNames` empty and requeues with a backoff delay.

### Thundering Herd Prevention

An in-memory cache tracks dispatches that haven't been confirmed by Kueue yet (`status.clusterName` not set). When scoring, in-flight GPU reservations are subtracted from available capacity. This prevents two workloads submitted simultaneously from both being sent to the same cluster based on stale state. Entries expire after 60 seconds as a safety net.

## Cluster Priority

You can bias the dispatcher toward specific clusters by labeling MultiKueueCluster resources:

```bash
kubectl label multikueuecluster worker-east1-cluster \
  dispatcher.kueue.x-k8s.io/priority=100 --context mgmt

kubectl label multikueuecluster worker-west3-cluster \
  dispatcher.kueue.x-k8s.io/priority=50 --context mgmt
```

Higher value = preferred when eviction scores are equal. Default is 0 if the label is absent.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Management Cluster                                          │
│                                                             │
│  Workload submitted → Kueue reserves quota                  │
│       │                                                     │
│       ▼                                                     │
│  Dispatcher watches Workloads with admission but no         │
│  clusterName or nominatedClusterNames                       │
│       │                                                     │
│       ├─── Read east1 ClusterQueue + Workloads (cache)      │
│       ├─── Read west3 ClusterQueue + Workloads (cache)      │
│       ├─── Check in-flight cache                            │
│       ├─── Score each cluster                               │
│       ├─── Select best (score → priority → freeGPUs)        │
│       │                                                     │
│       ▼                                                     │
│  Set status.nominatedClusterNames = [best]                  │
│       │                                                     │
│       ▼                                                     │
│  MultiKueue dispatches ONLY to nominated cluster            │
└─────────────────────────────────────────────────────────────┘
```

## Authentication

The dispatcher authenticates to worker clusters using the same mechanism as Kueue's built-in MultiKueue controller:

1. **Kubeconfig secrets** in the `kueue-system` namespace (named `<cluster>-kubeconfig`)
2. Each kubeconfig uses the **`gcp-auth-plugin`** exec credential provider for GKE Workload Identity
3. The plugin binary is copied into the pod via an **init container** from the project's Artifact Registry image (same pattern as `kueue-controller-manager`)
4. The dispatcher's K8s ServiceAccount has `roles/container.developer` IAM binding via Workload Identity Federation — no intermediate GCP service account needed

## Deployment

### Prerequisites

- Kueue v0.16+ on the management cluster
- MultiKueue configured with worker clusters
- Kubeconfig secrets for each worker cluster in `kueue-system` namespace
- IAM binding for the dispatcher's Workload Identity principal:
  ```bash
  gcloud projects add-iam-policy-binding PROJECT_ID \
    --member="principal://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/PROJECT_ID.svc.id.goog/subject/ns/kueue-system/sa/least-disruption-dispatcher" \
    --role="roles/container.developer"
  ```

### Install

```bash
# Apply RBAC, ConfigMap, and Deployment
kubectl apply -f dispatcher/deploy/rbac.yaml --context mgmt
kubectl apply -f dispatcher/deploy/config.yaml --context mgmt
kubectl apply -f dispatcher/deploy/deployment.yaml --context mgmt

# Set cluster priorities
kubectl label multikueuecluster worker-east1-cluster \
  dispatcher.kueue.x-k8s.io/priority=100 --context mgmt
kubectl label multikueuecluster worker-west3-cluster \
  dispatcher.kueue.x-k8s.io/priority=50 --context mgmt
```

### Switch Kueue to External Dispatching

Patch the `kueue-manager-config` ConfigMap to add `dispatcherName` under the `multiKueue` section:

```yaml
multiKueue:
  dispatcherName: "least-disruption-dispatcher"
```

Then restart the Kueue controller:

```bash
kubectl rollout restart deployment kueue-controller-manager \
  -n kueue-system --context mgmt
```

### Build

```bash
cd dispatcher/
docker build -t us-east1-docker.pkg.dev/PROJECT/REPO/least-disruption-dispatcher:latest .
docker push us-east1-docker.pkg.dev/PROJECT/REPO/least-disruption-dispatcher:latest
```

## Logging

Every dispatch decision is fully logged with structured fields:

```
scoring clusters for workload  gpus=6  priority=2000

cluster scored  cluster=worker-east1-cluster  clusterPriority=100
                score=0  feasible=true
                quotaTotal=8  quotaUsed=8  inFlightGPUs=0  freeGPUs=0
                admittedWorkloads=8

cluster scored  cluster=worker-west3-cluster  clusterPriority=50
                score=40  feasible=true
                quotaTotal=8  quotaUsed=6  inFlightGPUs=0  freeGPUs=2
                admittedWorkloads=6

nominating cluster  cluster=worker-west3-cluster
                    reason="only feasible cluster"
```

## Project Structure

```
dispatcher/
├── main.go                         # entry point, multi-cluster manager setup
├── pkg/
│   ├── dispatcher/dispatcher.go    # workload reconciler
│   ├── scorer/scorer.go            # cluster scoring + selection
│   ├── inflight/cache.go           # in-flight dispatch tracking
│   └── cluster/client.go           # worker cluster discovery + auth
├── deploy/
│   ├── deployment.yaml             # Deployment (with gcp-auth-plugin init container)
│   ├── rbac.yaml                   # ServiceAccount + ClusterRole + Binding
│   ├── config.yaml                 # ConfigMap with priority weights
│   └── kueue-config-patch.yaml     # Reference for patching Kueue config
├── Dockerfile
├── go.mod
└── go.sum
```

## Configuration

Priority weights and resource settings are in the `least-disruption-dispatcher-config` ConfigMap:

```yaml
priorityWeights:
  training-low: 1        # cheap to evict
  inference-high: 10     # expensive to evict
  training-critical: 1000 # effectively never evict
resourceName: "nvidia.com/gpu"
flavorName: "rtx-pro-6000"
clusterQueueName: "gpu-cluster-queue"
```

## Reverting to AllAtOnce

Remove `dispatcherName` from the Kueue manager config and restart:

```bash
# Edit the ConfigMap to remove the dispatcherName line
kubectl edit configmap kueue-manager-config -n kueue-system --context mgmt

# Restart Kueue
kubectl rollout restart deployment kueue-controller-manager \
  -n kueue-system --context mgmt
```

The dispatcher deployment can remain running — without `dispatcherName` set, Kueue ignores its nominations and uses AllAtOnce.
