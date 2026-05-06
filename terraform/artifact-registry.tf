# Repo for the custom Blackwell-optimized vLLM image. Image is tagged
# us-east1-docker.pkg.dev/<project>/vllm-blackwell/vllm-blackwell:<tag>.
# Also hosts the derived Kueue image (Kueue + gcp-auth-plugin) used by the
# 2-multikueue stack on the management cluster, and the
# least-disruption-dispatcher image.
resource "google_artifact_registry_repository" "vllm_blackwell" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_registry_repo
  description   = "vLLM (Blackwell sm_120 + FlashInfer), kueue-with-gcp-auth, and least-disruption-dispatcher images."
  format        = "DOCKER"

  depends_on = [google_project_service.default]
}

# Hosts the static gcp-auth-plugin binary image. Used as a source layer in
# the derived Kueue and dispatcher images that need to authenticate to
# worker cluster API servers via Connect Gateway.
resource "google_artifact_registry_repository" "gcp_auth_plugin" {
  project       = var.project_id
  location      = var.region
  repository_id = "gcp-auth-plugin"
  description   = "Static gcp-auth-plugin binary image for MultiKueue ClusterProfile credentials."
  format        = "DOCKER"

  depends_on = [google_project_service.default]
}
