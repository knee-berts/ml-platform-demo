# 2-multikueue — Kueue / MultiKueue + dispatcher

In-cluster control plane for GPU workload scheduling. Mirrors the upstream
[`gke-fleet-management/ai-platform/2-multikueue`](https://github.com/knee-berts/gke-fleet-management/tree/next-2026-demo/ai-platform/2-multikueue)
pattern using the modern (v3) Helm provider.

## What this installs

Per cluster (mgmt + each worker):

| Helm release | Source | Notes |
|---|---|---|
| `jobset` | `oci://registry.k8s.io/jobset/charts/jobset` | Required — Kueue's JobSet integration. |
| `lws` | `oci://registry.k8s.io/lws/charts/lws` | Optional (`enable_leaderworkerset = false` to skip). Required by `kueue/training-lws.yaml`. |
| `kueue` | `oci://registry.k8s.io/kueue/charts/kueue` | Manager cluster gets a custom image (see below). Worker clusters use the stock chart. |
| `kueue-config` | local `./charts/kueue-config` | WorkloadPriorityClass × 3, ResourceFlavor, ClusterQueue, LocalQueue × 2, training-jobs namespace. `isManager` toggles between hub (16 GPU quota + admission check) and worker (8 GPU quota). |

Hub-only:

| Helm release | Source | Notes |
|---|---|---|
| `multikueue-control-plane` | local `./charts/multikueue-control-plane` | AdmissionCheck, MultiKueueConfig, MultiKueueCluster (per worker), standalone ClusterProfile fallback. |
| `least-disruption-dispatcher` | local `./charts/dispatcher` | Custom MultiKueue dispatcher (Deployment + RBAC + ConfigMap) that scores worker clusters by least-disruption (priority-weighted preemption cost) before nominating. |

## Why a derived Kueue image instead of a kustomize postrender

The upstream stack uses a `postrender.binary_path` shell script
(`kueue-patches/kustomize.sh`) to inject a `gcp-auth-plugin` init container
into Kueue's manager Deployment. That violates the "no shell-out from
Terraform" constraint for this stack.

Kueue's helm chart (0.15.x) doesn't expose hooks for extra init containers
or volumes, so we can't add the plugin via values alone. The cleanest
helm-only path is to bake the plugin into the manager image:

```dockerfile
FROM <auth-plugin-image> AS plugin
FROM registry.k8s.io/kueue/kueue:v0.15.1
COPY --from=plugin /gcp-auth-plugin /plugins/gcp-auth-plugin
```

The Kueue manager then references `/plugins/gcp-auth-plugin` via
`multiKueue.clusterProfile.credentialsProviders` in the controller config.
No init container, no kustomize, no shell-out.

`docker/kueue-with-gcp-auth/{Dockerfile,cloudbuild.yaml}` build this image.
Build it once and point `kueue_manager_image_repository` /
`kueue_manager_image_tag` at the result. If you leave those empty Kueue
installs but MultiKueue cross-cluster admission won't work.

## Image build steps (run before `terraform apply`)

The dispatcher and the derived Kueue image are both built out of band — no
Terraform shell-out — and pushed to the `vllm-blackwell` Artifact Registry
repo provisioned by the 1-infrastructure stack.

```bash
# From the 2-multikueue/ directory.

# 1. Derived Kueue manager image (only needs to be rebuilt when Kueue
#    bumps versions or the auth plugin binary changes).
gcloud builds submit . \
  --config docker/kueue-with-gcp-auth/cloudbuild.yaml \
  --substitutions=_KUEUE_VERSION=v0.15.1

# 2. least-disruption-dispatcher image (built from the Go source in
#    ../dispatcher/, which has its own Dockerfile).
gcloud builds submit ../dispatcher \
  --config docker/dispatcher/cloudbuild.yaml \
  --substitutions=_TAG=latest
```

The terraform.tfvars.example sets `dispatcher_image` and
`kueue_manager_image_repository` / `kueue_manager_image_tag` to the targets
those Cloud Build configs produce by default.

## Prerequisites

1. The 1-infrastructure stack (`../terraform/`) has been applied — provides
   the GKE clusters, fleet membership, the Artifact Registry repos, and the
   `hub_cluster` / `worker_clusters` outputs this stack reads via
   `terraform_remote_state`.
2. The `gcp-auth-plugin` image referenced in `gcp_auth_plugin_image` exists.
   The 1-infrastructure stack creates the AR repo; you build/push the binary
   image yourself (one-time, out of band — it doesn't change between Kueue
   versions).
3. You've run both Cloud Builds above so `kueue-with-gcp-auth` and
   `least-disruption-dispatcher` images exist in Artifact Registry.
4. `gcloud auth application-default login` (or a service-account key) so
   Terraform's google + helm providers can reach the API servers.

## Usage

```bash
cd 2-multikueue
cp terraform.tfvars.example terraform.tfvars   # edit if needed

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

## Notes

- Default state backend is local (`terraform.tfstate` in this directory).
  Add a `backend "gcs"` block in `versions.tf` for shared state.
- Each cluster has its own aliased helm provider. Adding a third worker
  region means adding a `helm_release.kueue_worker2` set + a
  `kueue_config_worker2` set + extending the `MultiKueueCluster` list. A
  module-per-cluster refactor (matching the upstream `modules/kueue` pattern)
  is the right move if you grow past two workers.
- This stack does NOT install JobSet/LWS workloads (`kueue/training-jobset.yaml`,
  `kueue/training-lws.yaml`) — those are demo workloads, not infrastructure.
  They're applied at demo time by `demo-multikueue.sh`.
- HPAs (`kueue/hpa-inference*.yaml`) live in the `3-multi-cluster-inference-gateway`
  stack since they target the inference Deployment, not Kueue.
