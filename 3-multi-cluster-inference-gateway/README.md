# 3-multi-cluster-inference-gateway — gateway + EPP + inference routing

In-cluster routing infrastructure for the multi-cluster inference fleet.
Mirrors the upstream
[`gke-fleet-management/ai-platform/3-multi-cluster-inference-gateway`](https://github.com/knee-berts/gke-fleet-management/tree/next-2026-demo/ai-platform/3-multi-cluster-inference-gateway)
pattern using the modern (v3) Helm provider.

## What this installs

| Helm release | Target | Source | Notes |
|---|---|---|---|
| `inference-crds` | mgmt + each worker | local `./charts/inference-crds` | InferenceObjective CRD (alpha SIG resource not auto-installed by GKE). |
| `gateway-infrastructure` | mgmt | local `./charts/multi-cluster-inference-gateway` | Multi-cluster Gateway resource with regional ephemeral addresses. Mirrors the upstream `fleet-charts/multi-cluster-inference-gateway` chart. |
| `mgmt-routing` | mgmt | local `./charts/mgmt-routing` | HTTPRoute → GCPInferencePoolImport, GCPBackendPolicy with kv-cache custom metric, HealthCheckPolicy. |
| `inference-routing` | each worker | local `./charts/inference-routing` | InferencePool (with `networking.gke.io/export: "True"`), InferenceObjective × 2, EPP (Deployment + RBAC + ConfigMap + Service + PodMonitoring + metrics-reader secret), ComputeClass, AutoscalingMetric, pod-snapshot config. |
| `inference-application` | each worker | local `./charts/inference-application` | vLLM Deployment + ConfigMap + Service + ServiceAccount + HF token Secret. Replicas default to 0; the demo preflight scales them up. |

## What this does NOT install

- Any Kueue resources. Those live in the `2-multikueue` stack.
- The HPA — see "HPA ownership" below.

## HPA ownership

The HPA is **not** part of this chart. `demo-preemption.sh`'s pre-flight applies
`workers/hpa-inference.yaml` (`min=2`, `max=6`, KV-cache target 0.45) when the
demo starts; cleanup deletes the HPA and scales the inference Deployment back
to 0 so the GPU pool drains. Install ends with the data plane staged but idle —
no GPUs in use until the demo runs.

## Prerequisites

1. The 1-infrastructure stack (`../1-infrastructure/`) is applied — provides the
   cluster handles, multi-cluster ingress feature, and the pod-snapshot
   buckets / Workload Identity SAs that the inference-routing chart consumes
   via `terraform_remote_state`.
2. The 2-multikueue stack is applied — Kueue resources land before HPAs and
   InferencePool exports do, so MultiKueue admission is healthy by the time
   inference traffic arrives.
3. `gcloud auth application-default login` (or a service-account key) so the
   helm provider can reach the API servers.

## Usage

```bash
cd 3-multi-cluster-inference-gateway
cp terraform.tfvars.example terraform.tfvars   # edit if needed

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Then apply the application data plane (vLLM Deployment + Secret) with
`kubectl` against each worker context.

## Notes

- The EPP template in `charts/inference-routing/templates/epp.yaml` is the
  rendered output of the upstream `inferencepool` helm chart from
  gateway-api-inference-extension, with namespace + pool name templated in.
  Diff against `helm template inferencepool` of the upstream chart when
  upgrading EPP versions.
- `inference-crds` is intentionally minimal — only InferenceObjective.
  InferencePool ships with multi-cluster-ingress on GKE. If you move to a
  non-GKE cluster, add the upstream InferencePool CRD here.
