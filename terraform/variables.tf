variable "project_id" {
  description = "GCP project ID hosting the demo."
  type        = string
}

variable "region" {
  description = "Region for the management cluster, multi-cluster ingress config membership, and the Artifact Registry repo."
  type        = string
  default     = "us-east1"
}

variable "worker_regions" {
  description = "Regions to deploy worker GKE clusters into. Each gets a Standard cluster named ai-worker-<region> and an RTX PRO 6000 Blackwell node pool."
  type        = list(string)
  default     = ["us-east1", "us-west3"]
}

variable "management_cluster_name" {
  description = "Name of the Autopilot management cluster (hosts the multi-cluster Gateway, HTTPRoute, Kueue/MultiKueue control plane)."
  type        = string
  default     = "ai-management-cluster"
}

variable "artifact_registry_repo" {
  description = "Artifact Registry Docker repo name for the custom Blackwell-optimized vLLM image."
  type        = string
  default     = "vllm-blackwell"
}

variable "gpu_machine_type" {
  description = "GCE machine type for the worker GPU node pool. The g4-* family carries the RTX PRO 6000 Blackwell."
  type        = string
  default     = "g4-standard-48"
}

variable "gpu_count_per_node" {
  description = "Number of RTX PRO 6000 Blackwell GPUs attached to each node. Must match the chosen machine type."
  type        = number
  default     = 1
}

variable "gpu_node_min_count" {
  description = "Per-cluster minimum total node count for the GPU pool. 0 lets the cluster autoscaler drain the pool when no GPU workloads are scheduled (used for between-demo scale-to-zero)."
  type        = number
  default     = 0
}

variable "gpu_node_max_count" {
  description = "Per-cluster maximum total node count for the GPU pool. With the default 1 GPU per node, this caps total GPUs per cluster at gpu_node_max_count * gpu_count_per_node."
  type        = number
  default     = 8
}

variable "gpu_node_disk_size_gb" {
  description = "Boot disk size for GPU nodes. Large enough to cache the vLLM image plus the Llama 3.1 8B base + LoRA adapters."
  type        = number
  default     = 200
}

variable "release_channel" {
  description = "GKE release channel for both management and worker clusters. RAPID is required for the inference-extension and EPP v1.4.0 features used by this demo."
  type        = string
  default     = "RAPID"
}

# Node Auto-Provisioning (NAP) limits for the worker clusters. NAP backs the
# L4 Spot / L4 on-demand priorities of the inference-gpu ComputeClass.
variable "nap_cpu_max" {
  description = "Per-cluster ceiling on CPU cores NAP can provision. Sized for the L4 fallback path: g2-standard-12 = 12 vCPU, room for ~8 nodes."
  type        = number
  default     = 128
}

variable "nap_memory_max_gb" {
  description = "Per-cluster ceiling on memory (GiB) NAP can provision."
  type        = number
  default     = 512
}

variable "nap_l4_max_count" {
  description = "Per-cluster ceiling on the number of nvidia-l4 GPUs NAP can provision. Caps the L4 fallback path."
  type        = number
  default     = 8
}

variable "model_weights_location" {
  description = "Location for the model-weights bucket. US multi-region keeps a single copy globally accessible to both worker regions; switch to a single region (e.g. us-east1) if you want to colocate weights with one cluster."
  type        = string
  default     = "US"
}

variable "manage_project_services" {
  description = "Whether Terraform manages the google_project_service resources for the demo's required APIs. Default true. Set to false ONLY when running with a cross-project SA that can't pass the provider's serviceusage LIST refresh check; you must then enable the APIs in apis.tf::local.required_services manually with `gcloud services enable`."
  type        = bool
  default     = true
}

variable "enable_blackwell_pool" {
  description = "Whether to provision a Terraform-managed RTX PRO 6000 Blackwell node pool on each worker. Default false because Blackwell quota and zonal availability are scarce; the demo runs on NVIDIA L4 (Spot first, on-demand fallback) via the inference-gpu ComputeClass. Set true only if you have explicit Blackwell quota in the worker regions."
  type        = bool
  default     = false
}
