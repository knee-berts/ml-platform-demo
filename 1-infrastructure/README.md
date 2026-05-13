# 1-infrastructure — GCP infrastructure for the vLLM demo

Provisions everything in **Google Cloud** that the demo needs *outside* of the
GKE workloads themselves. In-cluster bits (vLLM Deployment, EPP, InferencePool,
Kueue, MultiKueue) are installed by the `2-multikueue/` and
`3-multi-cluster-inference-gateway/` Helm-driven Terraform stacks.

## What this creates

| Resource | Notes |
|---|---|
| Project services | `container`, `gkehub`, `connectgateway`, `multiclusteringress`, `multiclusterservicediscovery`, `artifactregistry`, monitoring/logging, etc. |
| Proxy subnets | One `GLOBAL_MANAGED_PROXY` `/23` per region used by any cluster — required for the multi-cluster Gateway. |
| Cluster service accounts | `sa-management` + `sa-worker`, each with the standard GKE node roles plus `artifactregistry.reader`, `monitoring.viewer`, `autoscaling.metricsWriter`. |
| Workload Identity bindings | `gke-mcs/gke-mcs-importer`, `custom-metrics/custom-metrics-stackdriver-adapter`, `kueue-system/kueue-controller-manager`. |
| Management cluster | **Standard** (not Autopilot), RAPID channel, fleet-registered, Gateway API enabled, Managed Prometheus. Default node pool: `e2-standard-8`, autoscaling 1–4. |
| Worker clusters | One **Standard** cluster per `worker_regions` entry, fleet-registered, Gateway API enabled, Managed Prometheus, Node Auto-Provisioning enabled with `nvidia-l4` / cpu / memory limits. Each has a small `e2-standard-4` system pool (autoscaling 1–4). |
| Static accelerator pool | **Opt-in.** Created only when `static_accelerator_machine_type` is set; one fixed pool per worker. Family inferred from prefix (`g4-*` → Blackwell, `g2-*` → L4). |
| L4 fallback | **No Terraform-managed L4 pool by default.** NAP creates `g2-standard-12` Spot / on-demand pools on demand, driven by the `inference-gpu` ComputeClass in `3-multi-cluster-inference-gateway/`. Per-cluster ceiling: `nap_l4_max_count` (default 8). |
| Multi-Cluster Ingress | Fleet feature with the management cluster as config membership. |
| Artifact Registry | `vllm-blackwell` Docker repo in the management region for the custom vLLM image. |

## What this does *not* create

- Anything inside a GKE cluster (Deployments, Services, Gateway, HTTPRoute, EPP, InferencePool, Kueue/MultiKueue config, HPAs). Stacks 2 and 3 cover those.
- Hugging Face token Secret — created by stack 3.
- Custom Metrics Stackdriver Adapter Deployment — install it via stack 3; the IAM binding here lets it work once installed.

## Two provisioning modes

### Happy path (default) — NAP-driven L4

`static_accelerator_machine_type = ""` (or unset). No fixed accelerator pool.
The `inference-gpu` ComputeClass in stack 3 drives Node Auto-Provisioning to
materialize `g2-standard-12` (L4) Spot or on-demand pools when GPUs are
needed, and the cluster autoscaler drains them between demo runs.

- Use `Dockerfile.l4` for the vLLM image (FA2 backend, fp8 KV cache).
- Quota: `NVIDIA_L4_GPUS` per worker region (default ceiling 8).
- No reservation needed — L4 is broadly available.

### Heavy / static accelerator pool — opt-in

Set `static_accelerator_machine_type` to attach a fixed GPU pool to every
worker cluster. The accelerator type is inferred from the machine-type prefix:

| Prefix | Accelerator | Dockerfile | Reservation? |
|---|---|---|---|
| `g4-*` | RTX PRO 6000 (Blackwell, sm_120) | `Dockerfile.blackwell` | **Strongly recommended** |
| `g2-*` | L4 (sm_89) | `Dockerfile.l4` | Optional |

> **Quota check before applying.** Confirm GPU quota in *every*
> `worker_regions` entry. With the defaults you need either
> `NVIDIA_RTX_PRO_6000_GPUS >= 8` (Blackwell) or `NVIDIA_L4_GPUS >= 8` (L4),
> per region, plus matching CPU quota for the chosen machine family.
>
> **Reservations for Blackwell.** RTX PRO 6000 inventory is scarce in any
> single region. Provision a Compute Engine reservation in each worker region
> and pass its name via `static_accelerator_reservation`. Without one, pool
> creation will usually fail with `ZONE_RESOURCE_POOL_EXHAUSTED`.

Example tfvars for the heavy Blackwell mode:

```hcl
worker_regions                    = ["us-east1", "us-central1"]
static_accelerator_machine_type   = "g4-standard-48"
static_accelerator_count_per_node = 1
static_accelerator_max_node_count = 8
static_accelerator_reservation    = "blackwell-demo-reservation"
```

## Prerequisites

1. The project exists and billing is enabled.
2. You have `roles/owner` or equivalent on it.
3. Quota — see the table above for the mode you're using.
4. `gcloud auth application-default login` (or a service-account key set via
   `GOOGLE_APPLICATION_CREDENTIALS`).

## Usage

```bash
cd 1-infrastructure
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — at minimum set project_id; uncomment the
# static_accelerator_* block if you want a fixed pool.

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Then, once the clusters are up:

```bash
# wires up kubectl contexts mgmt / worker-east1 / worker-central1
$(terraform output -raw get_credentials_commands | jq -r '.[]')
```

…and continue with stack 2 and stack 3, or use `scripts/install.sh` from the
repo root.

## Layout

```
1-infrastructure/
├── versions.tf              providers + version constraints
├── variables.tf             inputs (defaults match the happy path)
├── apis.tf                  google_project_service for required APIs
├── network.tf               default VPC lookup + per-region proxy subnets
├── iam.tf                   cluster SAs, project IAM, WI bindings
├── clusters.tf              mgmt + worker Standard clusters, default + static accelerator pools
├── fleet.tf                 fleet + multi-cluster ingress feature
├── artifact-registry.tf     vllm-blackwell + gcp-auth-plugin Docker repos
├── storage.tf               model-weights + pod-snapshot GCS buckets
├── inference-iam.tf         vLLM + pod-snapshot KSA Workload Identity bindings
├── outputs.tf               cluster handles + get-credentials commands
└── terraform.tfvars.example sample inputs
```

## Notes on choices

- **All Standard, no Autopilot.** The management cluster is a small Standard
  cluster with autoscaling on the default pool; this gives Terraform/Helm
  full control over the node config (e.g. `gcfs_config`, `image_type`) and
  matches the worker clusters' management story.
- **`ignore_changes` on worker clusters and the static accelerator pool.**
  Demo scripts patch ClusterQueue quotas and the cluster autoscaler resizes
  the pool at runtime. Ignoring those fields prevents Terraform from fighting
  the demo.
- **Static accelerator pool min = 0.** True HPA scale-to-zero isn't available
  on GKE Standard, but the *cluster autoscaler* can drain the pool once
  `delete_inference_stack` removes the HPA + Deployment between demo runs.
  See the HPA section in the root `CLAUDE.md`.
- **No remote backend.** Default is local state. Add a `backend "gcs"` block
  in `versions.tf` and re-`init` if you want shared state.
