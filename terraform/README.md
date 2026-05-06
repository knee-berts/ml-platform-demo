# Terraform — GCP infrastructure for the Blackwell vLLM demo

Provisions everything in **Google Cloud** that the demo needs *outside* of the
GKE clusters themselves. In-cluster bits (vLLM Deployment, EPP, InferencePool,
Kueue, MultiKueue, ArgoCD, etc.) stay as the YAML in `../workers/`,
`../mgmt/`, and `../kueue/` — `kubectl apply` those after `terraform apply`.

## What this creates

| Resource | Notes |
|---|---|
| Project services | `container`, `gkehub`, `connectgateway`, `multiclusteringress`, `multiclusterservicediscovery`, `artifactregistry`, monitoring/logging, etc. |
| Proxy subnets | One `GLOBAL_MANAGED_PROXY` `/23` per region used by any cluster — required for the multi-cluster Gateway. |
| Cluster service accounts | `sa-management` + `sa-worker`, each with the standard GKE node roles plus `artifactregistry.reader`, `monitoring.viewer`, `autoscaling.metricsWriter`. |
| Workload Identity bindings | `gke-mcs/gke-mcs-importer`, `custom-metrics/custom-metrics-stackdriver-adapter`, `kueue-system/kueue-controller-manager`. |
| Management cluster | Autopilot, RAPID channel, fleet-registered, Gateway API enabled, Managed Prometheus. |
| Worker clusters | One Standard cluster per `worker_regions` entry, fleet-registered, Gateway API enabled, Managed Prometheus. |
| GPU node pool | One per worker cluster: `g4-standard-48` (1× RTX PRO 6000 Blackwell), autoscaling 0–8 nodes, GKE-default driver, COS, GPU taint. |
| Multi-Cluster Ingress | Fleet feature with the management cluster as config membership. |
| Artifact Registry | `vllm-blackwell` Docker repo in the management region for the custom Blackwell-optimized vLLM image. |

## What this does *not* create

- Anything inside a GKE cluster (Deployments, Services, Gateway, HTTPRoute, EPP, InferencePool, Kueue/MultiKueue config, HPAs, Argo CD).
- Hugging Face token Secret — keep that in `workers/secret.yaml`.
- Custom Metrics Stackdriver Adapter Deployment — install it via Helm/manifest after the clusters exist; the IAM binding here lets it work once installed.

## Prerequisites

1. The project (default `kubecon-fleets-demo-1`) exists and billing is enabled.
2. You have `roles/owner` or equivalent on it.
3. RTX PRO 6000 Blackwell quota in each `worker_regions` entry. With the
   defaults you need `NVIDIA_RTX_PRO_6000_GPUS >= 8` per region, plus matching
   CPU quota for the `g4-standard-48` family.
4. `gcloud auth application-default login` (or a service-account key set
   via `GOOGLE_APPLICATION_CREDENTIALS`).

## Usage

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars if you want non-default project/regions/sizing

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Then, once the clusters are up:

```bash
# wires up kubectl contexts mgmt / worker-east1 / worker-west3
$(terraform output -raw get_credentials_commands | jq -r '.[]')
```

…and continue with the manifest application steps from the root `README.md`.

## Layout

```
terraform/
├── versions.tf              providers + version constraints
├── variables.tf             inputs (defaults match the demo)
├── apis.tf                  google_project_service for required APIs
├── network.tf               default VPC lookup + per-region proxy subnets
├── iam.tf                   cluster SAs, project IAM, WI bindings
├── clusters.tf              mgmt (Autopilot) + worker (Standard) + GPU node pool
├── fleet.tf                 multi-cluster ingress feature
├── artifact-registry.tf     vllm-blackwell Docker repo
├── outputs.tf               cluster handles + get-credentials commands
└── terraform.tfvars.example sample inputs
```

## Notes on choices

- **No remote backend.** Default is local state. Add a `backend "gcs"` block
  in `versions.tf` and re-`init` if you want shared state.
- **`ignore_changes` on worker clusters and the GPU node pool.** The demo
  scripts patch ClusterQueue quotas and the cluster autoscaler resizes the
  pool at runtime. Ignoring those fields prevents Terraform from fighting the
  demo.
- **GPU node pool min = 0.** True HPA scale-to-zero isn't available on GKE
  Standard, but the *cluster autoscaler* can drain the GPU pool once
  `delete_inference_stack` removes the HPA + Deployment between demo runs.
  See the HPA section in the root `CLAUDE.md`.
- **Helm/ArgoCD intentionally omitted.** The upstream
  `gke-fleet-management/ai-platform/1-infrastructure` module installs
  ArgoCD and the cluster-profile syncer via Helm. This demo applies its
  manifests directly via `kubectl`, so those resources aren't needed here.
