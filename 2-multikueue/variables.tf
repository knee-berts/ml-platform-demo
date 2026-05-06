variable "project_id" {
  description = "GCP project ID hosting the demo. Must match the value used by the 1-infrastructure stack (terraform/)."
  type        = string
}

variable "region" {
  description = "Region for the google provider. Defaults to the management cluster's region."
  type        = string
  default     = "us-east1"
}

variable "kueue_version" {
  description = "Kueue helm chart version. Pulled from oci://registry.k8s.io/kueue/charts/kueue."
  type        = string
  default     = "0.15.1"
}

variable "jobset_version" {
  description = "JobSet helm chart version. Pulled from oci://registry.k8s.io/jobset/charts/jobset."
  type        = string
  default     = "0.10.0"
}

variable "leaderworkerset_version" {
  description = "LeaderWorkerSet helm chart version. Pulled from oci://registry.k8s.io/lws/charts/lws."
  type        = string
  default     = "0.7.0"
}

variable "enable_leaderworkerset" {
  description = "Install the LeaderWorkerSet operator on each cluster. The demo's training-lws.yaml requires it; training-jobset.yaml (default training path) does not."
  type        = bool
  default     = true
}

variable "kueue_manager_image_repository" {
  description = "Override the kueue-controller-manager image repository on the management cluster only. Use a derived image that contains the gcp-auth-plugin binary at /plugins/gcp-auth-plugin (see docker/Dockerfile). When empty, the stock Kueue image is used and MultiKueue cross-cluster auth will not work."
  type        = string
  default     = ""
}

variable "kueue_manager_image_tag" {
  description = "Tag for kueue_manager_image_repository. Typically tracks kueue_version."
  type        = string
  default     = ""
}

variable "dispatcher_image" {
  description = "Full image reference for the least-disruption-dispatcher (built from /home/nickeberts/blackwell-vllm/dispatcher)."
  type        = string
  default     = "us-east1-docker.pkg.dev/kubecon-fleets-demo-1/vllm-blackwell/least-disruption-dispatcher:latest"
}

variable "gcp_auth_plugin_image" {
  description = "Full image reference for the gcp-auth-plugin source image. Used as the init container in the dispatcher and (logically) baked into the derived Kueue image."
  type        = string
  default     = "us-east1-docker.pkg.dev/kubecon-fleets-demo-1/gcp-auth-plugin/gcp-auth-plugin:v0.0.1"
}

variable "gpu_resource_flavor_name" {
  description = "Name of the Kueue ResourceFlavor that the GPU pool maps to."
  type        = string
  default     = "rtx-pro-6000"
}

variable "gpu_node_label" {
  description = "Node label key/value the ResourceFlavor selects on. Must match the GPU node pool's nodeSelector. Set to {} to match any node."
  type        = map(string)
  default = {
    "cloud.google.com/gke-accelerator" = "nvidia-rtx-pro-6000"
  }
}

variable "infra_state_path" {
  description = "Local path to the 1-infrastructure (terraform/) state file. Override if you keep state somewhere else."
  type        = string
  default     = "../terraform/terraform.tfstate"
}
