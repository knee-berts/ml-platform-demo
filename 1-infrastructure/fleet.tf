# Explicit Fleet resource for the project. A fleet exists implicitly the
# first time a cluster auto-registers (via the `fleet { project = ... }`
# block on google_container_cluster), but creating the resource here:
#   1. Makes ordering deterministic — clusters depend on the fleet.
#   2. Lets us set a display_name + default cluster config in one place.
#   3. Surfaces the fleet in `terraform state` for documentation/auditing.
resource "google_gke_hub_fleet" "default" {
  project      = var.project_id
  display_name = "AI Platform Demo Fleet"

  depends_on = [google_project_service.default]
}

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
    google_gke_hub_fleet.default,
    google_container_cluster.management,
  ]
}
