provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_client_config" "default" {}

data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = var.infra_state_path
  }
}

locals {
  hub     = data.terraform_remote_state.infra.outputs.hub_cluster
  workers = data.terraform_remote_state.infra.outputs.worker_clusters

  # All distinct regions the multi-cluster Gateway needs ephemeral addresses for.
  all_regions = distinct(concat(
    [local.hub.location],
    [for c in local.workers : c.location],
  ))

  gateway_addresses = [
    for r in local.all_regions : {
      type  = "networking.gke.io/ephemeral-ipv4-address/${r}"
      value = r
    }
  ]

  scale_from_zero_set = toset([for i in var.scale_from_zero_worker_indexes : tostring(i)])
}

# ─── Helm providers ─────────────────────────────────────────────────────────

provider "helm" {
  kubernetes = {
    host                   = "https://${local.hub.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(local.hub.ca_cert)
  }
}

provider "helm" {
  alias = "worker0"
  kubernetes = {
    host                   = "https://${local.workers[0].endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(local.workers[0].ca_cert)
  }
}

provider "helm" {
  alias = "worker1"
  kubernetes = {
    host                   = "https://${local.workers[1].endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(local.workers[1].ca_cert)
  }
}

# ─── Inference CRDs (all clusters) ──────────────────────────────────────────
# InferenceObjective CRD ships outside GKE (alpha SIG resource); InferencePool
# is GKE-managed when multi-cluster ingress is enabled.

resource "helm_release" "inference_crds_hub" {
  name             = "inference-crds"
  namespace        = "inference-system"
  create_namespace = true
  chart            = "${path.module}/charts/inference-crds"
}

resource "helm_release" "inference_crds_worker0" {
  provider         = helm.worker0
  name             = "inference-crds"
  namespace        = "inference-system"
  create_namespace = true
  chart            = "${path.module}/charts/inference-crds"
}

resource "helm_release" "inference_crds_worker1" {
  provider         = helm.worker1
  name             = "inference-crds"
  namespace        = "inference-system"
  create_namespace = true
  chart            = "${path.module}/charts/inference-crds"
}

# ─── Multi-cluster Gateway (hub only) ───────────────────────────────────────

resource "helm_release" "gateway_infrastructure" {
  name             = "gateway-infrastructure"
  namespace        = var.gateway_namespace
  create_namespace = true
  chart            = "${path.module}/charts/multi-cluster-inference-gateway"

  values = [yamlencode({
    gateway = {
      name             = var.gateway_name
      gatewayClassName = "gke-l7-cross-regional-internal-managed-mc"
      addresses        = local.gateway_addresses
      listeners = [
        {
          name     = "http"
          protocol = "HTTP"
          port     = 80
          allowedRoutes = {
            namespaces = {
              from = "All"
            }
          }
        }
      ]
    }
  })]
}

# ─── Mgmt-side routing (hub only) ───────────────────────────────────────────

resource "helm_release" "mgmt_routing" {
  name             = "mgmt-routing"
  namespace        = var.gateway_namespace
  create_namespace = false
  chart            = "${path.module}/charts/mgmt-routing"

  values = [yamlencode({
    inferencePoolName   = var.inference_pool_name
    inferenceNamespace  = var.inference_namespace
    gatewayName         = var.gateway_name
    gatewayNamespace    = var.gateway_namespace
    kvCacheThresholdPct = var.kv_cache_threshold_percent
  })]

  depends_on = [helm_release.gateway_infrastructure]
}

# ─── Worker-side inference data plane ───────────────────────────────────────
# One release per worker, each carrying: namespace, ComputeClass, InferencePool,
# InferenceObjectives, EPP (Deployment + RBAC + ConfigMap + Service + monitoring),
# AutoscalingMetric, HPA, and pod-snapshot config.

resource "helm_release" "inference_routing_worker0" {
  provider         = helm.worker0
  name             = "inference-routing"
  namespace        = var.inference_namespace
  create_namespace = true
  chart            = "${path.module}/charts/inference-routing"

  values = [yamlencode({
    inferencePoolName              = var.inference_pool_name
    inferenceNamespace             = var.inference_namespace
    computeClassName               = var.compute_class_name
    eppImage                       = var.epp_image
    saturationKvCacheUtilThreshold = var.saturation_kv_cache_util_threshold
    saturationQueueDepthThreshold  = var.saturation_queue_depth_threshold
    enableScaleFromZero            = contains(local.scale_from_zero_set, "0")
    podSnapshotBucket              = data.terraform_remote_state.infra.outputs.pod_snapshot_buckets[local.workers[0].location]
    podSnapshotServiceAccount      = data.terraform_remote_state.infra.outputs.pod_snapshot_service_account
  })]

  depends_on = [helm_release.inference_crds_worker0]
}

resource "helm_release" "inference_routing_worker1" {
  provider         = helm.worker1
  name             = "inference-routing"
  namespace        = var.inference_namespace
  create_namespace = true
  chart            = "${path.module}/charts/inference-routing"

  values = [yamlencode({
    inferencePoolName              = var.inference_pool_name
    inferenceNamespace             = var.inference_namespace
    computeClassName               = var.compute_class_name
    eppImage                       = var.epp_image
    saturationKvCacheUtilThreshold = var.saturation_kv_cache_util_threshold
    saturationQueueDepthThreshold  = var.saturation_queue_depth_threshold
    enableScaleFromZero            = contains(local.scale_from_zero_set, "1")
    podSnapshotBucket              = data.terraform_remote_state.infra.outputs.pod_snapshot_buckets[local.workers[1].location]
    podSnapshotServiceAccount      = data.terraform_remote_state.infra.outputs.pod_snapshot_service_account
  })]

  depends_on = [helm_release.inference_crds_worker1]
}
