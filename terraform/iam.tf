# Two cluster service accounts — one shared by the management cluster, one
# shared across all worker clusters. Mirrors the upstream gke-fleet-management
# pattern and keeps node IAM minimal.

resource "google_service_account" "clusters" {
  for_each = toset(["management", "worker"])

  project      = var.project_id
  account_id   = "sa-${each.key}"
  display_name = "Service account for the ${each.key} GKE cluster(s)"
}

# Standard node SA roles + autoscaling.metricsWriter (HPA on custom metrics)
# + artifactregistry.reader (pulling the custom vLLM image from this repo).
resource "google_project_iam_member" "clusters" {
  for_each = {
    for o in distinct(flatten([
      for sa in google_service_account.clusters : [
        for role in [
          "roles/container.defaultNodeServiceAccount",
          "roles/monitoring.metricWriter",
          "roles/monitoring.viewer",
          "roles/logging.logWriter",
          "roles/artifactregistry.reader",
          "roles/serviceusage.serviceUsageConsumer",
          "roles/autoscaling.metricsWriter",
          ] : {
          email = sa.email
          role  = role
        }
      ]
    ])) : "${o.email}/${o.role}" => o
  }

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${each.value.email}"
}

# Multi-Cluster Services importer — needed for the InferencePool exports/imports
# the multi-cluster Gateway HTTPRoute targets.
resource "google_project_iam_member" "gke_mcs_importer" {
  project = var.project_id
  role    = "roles/compute.networkViewer"
  member  = "principal://iam.googleapis.com/projects/${data.google_project.default.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/gke-mcs/sa/gke-mcs-importer"

  depends_on = [google_container_cluster.management]
}

# Custom Metrics Stackdriver Adapter — backs the vllm:kv_cache_usage_perc HPA.
resource "google_project_iam_member" "custom_metrics_adapter" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "principal://iam.googleapis.com/projects/${data.google_project.default.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/custom-metrics/sa/custom-metrics-stackdriver-adapter"

  depends_on = [google_container_cluster.management]
}

# Kueue controller manager (running on the management cluster) needs to talk
# to worker cluster API servers via Connect Gateway to dispatch MultiKueue jobs.
resource "google_project_iam_member" "kueue_controller_manager" {
  for_each = toset([
    "roles/container.developer",
    "roles/gkehub.gatewayEditor",
  ])

  project = var.project_id
  role    = each.value
  member  = "principal://iam.googleapis.com/projects/${data.google_project.default.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/kueue-system/sa/kueue-controller-manager"

  depends_on = [google_container_cluster.management]
}
