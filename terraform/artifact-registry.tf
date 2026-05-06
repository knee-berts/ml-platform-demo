# Repo for the custom Blackwell-optimized vLLM image. Image is tagged
# us-east1-docker.pkg.dev/<project>/vllm-blackwell/vllm-blackwell:<tag>.
resource "google_artifact_registry_repository" "vllm_blackwell" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_registry_repo
  description   = "Custom vLLM image with Blackwell (sm_120) optimizations and FlashInfer."
  format        = "DOCKER"

  depends_on = [google_project_service.default]
}
