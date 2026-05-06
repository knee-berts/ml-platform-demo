# Multi-Cluster Ingress feature, with the management cluster as the config
# membership. This is what lets the Gateway in mgmt/gateway.yaml resolve the
# InferencePool exports across worker clusters.
resource "google_gke_hub_feature" "multiclusteringress" {
  name     = "multiclusteringress"
  location = "global"
  project  = var.project_id

  spec {
    multiclusteringress {
      config_membership = "projects/${var.project_id}/locations/${var.region}/memberships/${google_container_cluster.management.name}"
    }
  }

  depends_on = [
    google_project_service.default,
    google_container_cluster.management,
  ]
}
