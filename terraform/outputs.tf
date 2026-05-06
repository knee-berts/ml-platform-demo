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

# Downstream stacks (2-multikueue, 3-multi-cluster-inference-gateway) consume
# these via terraform_remote_state. Endpoint + ca_cert are sensitive so we
# mark the outputs accordingly; consumers must reference them in providers.
output "hub_cluster" {
  description = "Management (hub) GKE cluster connection details."
  value = {
    name     = google_container_cluster.management.name
    location = google_container_cluster.management.location
    endpoint = google_container_cluster.management.endpoint
    ca_cert  = google_container_cluster.management.master_auth[0].cluster_ca_certificate
  }
  sensitive = true
}

output "worker_clusters" {
  description = "Worker GKE cluster connection details, ordered to match var.worker_regions."
  value = [
    for r in var.worker_regions : {
      name     = google_container_cluster.workers[r].name
      location = google_container_cluster.workers[r].location
      endpoint = google_container_cluster.workers[r].endpoint
      ca_cert  = google_container_cluster.workers[r].master_auth[0].cluster_ca_certificate
    }
  ]
  sensitive = true
}

output "model_weights_bucket" {
  description = "GCS bucket name holding Llama base weights and LoRA adapters (gs://<name>)."
  value       = google_storage_bucket.model_weights.name
}

output "pod_snapshot_buckets" {
  description = "Map of worker region to the pod-snapshot bucket name for that region."
  value       = { for r, b in google_storage_bucket.pod_snapshots : r => b.name }
}

output "inference_service_account" {
  description = "Email of the GSA the vLLM Workload Identity binding maps to (bind via iam.gke.io/gcp-service-account annotation on KSA inference-server/vllm-llama3-8b-instruct)."
  value       = google_service_account.inference.email
}

output "pod_snapshot_service_account" {
  description = "Email of the GSA bound to KSA inference-server/vllm-snapshot-sa for pod-snapshot writes."
  value       = google_service_account.pod_snapshot.email
}

output "gcp_auth_plugin_repo" {
  description = "Artifact Registry path that hosts the gcp-auth-plugin source image."
  value       = "${google_artifact_registry_repository.gcp_auth_plugin.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.gcp_auth_plugin.repository_id}"
}
