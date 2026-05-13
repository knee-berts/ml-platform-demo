output "kueue_namespace" {
  description = "Namespace where Kueue (and all kueue-config / multikueue / dispatcher resources) are installed."
  value       = "kueue-system"
}

output "kueue_chart_version" {
  description = "Kueue helm chart version installed on each cluster."
  value       = var.kueue_version
}

output "kueue_manager_image" {
  description = "Image used by the management cluster's kueue-controller-manager. Empty when the stock chart image is used (no MultiKueue cross-cluster auth)."
  value = var.kueue_manager_image_repository == "" ? "" : format(
    "%s:%s",
    var.kueue_manager_image_repository,
    var.kueue_manager_image_tag != "" ? var.kueue_manager_image_tag : var.kueue_version,
  )
}

output "multikueue_clusters" {
  description = "MultiKueueCluster names registered on the management cluster — referenced from MultiKueueConfig.spec.clusters."
  value = [
    for c in data.terraform_remote_state.infra.outputs.worker_clusters :
    "worker-${replace(c.location, "us-", "")}-cluster"
  ]
}
