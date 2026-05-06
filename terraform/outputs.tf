output "management_cluster_name" {
  description = "Name of the Autopilot management cluster."
  value       = google_container_cluster.management.name
}

output "management_cluster_location" {
  description = "Region of the management cluster (also the multi-cluster ingress config membership location)."
  value       = google_container_cluster.management.location
}

output "worker_cluster_names" {
  description = "Names of the worker GKE clusters, one per worker_regions entry."
  value       = [for c in google_container_cluster.workers : c.name]
}

output "worker_cluster_locations" {
  description = "Map of worker cluster name to region."
  value       = { for c in google_container_cluster.workers : c.name => c.location }
}

output "cluster_service_accounts" {
  description = "Email addresses of the management and worker cluster service accounts."
  value       = { for k, sa in google_service_account.clusters : k => sa.email }
}

output "artifact_registry_repo" {
  description = "Fully-qualified Artifact Registry path for the vLLM image (without the image name/tag)."
  value       = "${google_artifact_registry_repository.vllm_blackwell.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.vllm_blackwell.repository_id}"
}

output "get_credentials_commands" {
  description = "Copy/paste commands to populate kubectl contexts for all clusters in this stack."
  value = concat(
    [
      "gcloud container clusters get-credentials ${google_container_cluster.management.name} --region ${google_container_cluster.management.location} --project ${var.project_id}",
    ],
    [
      for c in google_container_cluster.workers :
      "gcloud container clusters get-credentials ${c.name} --region ${c.location} --project ${var.project_id}"
    ],
  )
}
