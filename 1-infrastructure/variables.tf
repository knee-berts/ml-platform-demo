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
  description = "Regions to deploy worker GKE Standard clusters into. Each gets a cluster named ai-worker-<region>. By default the worker GPUs come from NAP-driven L4 pools (happy path); set var.static_accelerator_machine_type to attach a fixed accelerator pool to every worker."
  type        = list(string)
  default     = ["us-east1", "us-central1"]
}

variable "management_cluster_name" {
  description = "Name of the Standard management cluster (hosts the multi-cluster Gateway, HTTPRoute, Kueue/MultiKueue control plane). No GPUs."
  type        = string
  default     = "ai-management-cluster"
}

variable "artifact_registry_repo" {
  description = "Artifact Registry Docker repo name for the custom vLLM image."
  type        = string
  default     = "vllm-blackwell"
}

variable "release_channel" {
  description = "GKE release channel for both management and worker clusters. RAPID is required for the inference-extension and EPP v1.4.0 features used by this demo."
  type        = string
  default     = "RAPID"
}

# ─────────────────────────────────────────────────────────────────────────────
# Management node pool — Standard cluster, autoscaling default pool.
# ─────────────────────────────────────────────────────────────────────────────

variable "management_machine_type" {
  description = "Machine type for the management cluster's default node pool. e2-standard-8 (8 vCPU / 32 GB) comfortably hosts the multi-cluster Gateway, HTTPRoute, MultiKueue, Kueue, and the dispatcher."
  type        = string
  default     = "e2-standard-8"
}

variable "management_min_node_count" {
  description = "Per-zone minimum nodes in the management default pool. 1 keeps the control plane warm at idle."
  type        = number
  default     = 1
}

variable "management_max_node_count" {
  description = "Per-zone maximum nodes in the management default pool."
  type        = number
  default     = 4
}

variable "management_disk_size_gb" {
  description = "Boot disk size for management nodes."
  type        = number
  default     = 100
}

# ─────────────────────────────────────────────────────────────────────────────
# Worker node auto-provisioning (NAP) — happy path.
#
# When var.static_accelerator_machine_type is unset (the default), the worker
# clusters have no fixed GPU pool. The inference-gpu ComputeClass drives NAP to
# materialize L4 (g2-standard-12) Spot or on-demand pools on demand. NAP also
# scales them to 0 between demo runs.
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# Static accelerator node pool — heavy / thickly-provisioned mode.
#
# Off by default (var.static_accelerator_machine_type = ""). Setting this to a
# GPU machine type creates one fixed accelerator node pool per worker cluster,
# bypassing NAP. The accelerator type is inferred from the machine-type prefix:
#
#   g4-*  → nvidia-rtx-pro-6000  (Blackwell, sm_120 — needs RTX PRO 6000 quota)
#   g2-*  → nvidia-l4            (Ada Lovelace, sm_89 — needs L4 quota)
#
# IMPORTANT: confirm you have GPU quota in every var.worker_regions entry, and
# for Blackwell pools you will almost always want a capacity reservation —
# RTX PRO 6000 inventory in any single region is scarce and pool creation will
# fail without one. See README.md → "Static accelerator pool" for details.
# ─────────────────────────────────────────────────────────────────────────────

variable "static_accelerator_machine_type" {
  description = "If non-empty, attach a fixed (static) accelerator node pool of this machine type to every worker cluster. Empty disables the static pool and lets NAP provision L4 on demand (the demo's happy path). Supported prefixes: g4-* (Blackwell RTX PRO 6000), g2-* (L4)."
  type        = string
  default     = ""

  validation {
    condition     = var.static_accelerator_machine_type == "" || can(regex("^(g4|g2)-", var.static_accelerator_machine_type))
    error_message = "static_accelerator_machine_type must be empty or start with 'g4-' (Blackwell) or 'g2-' (L4)."
  }
}

variable "static_accelerator_count_per_node" {
  description = "GPUs per node in the static accelerator pool. Must match the machine type's published GPU count (e.g. g4-standard-48 = 1, g4-standard-384 = 8)."
  type        = number
  default     = 1
}

variable "static_accelerator_min_node_count" {
  description = "Per-cluster minimum total node count for the static accelerator pool. 0 lets the cluster autoscaler drain the pool when no GPU workloads are scheduled (used for between-demo scale-to-zero)."
  type        = number
  default     = 0
}

variable "static_accelerator_max_node_count" {
  description = "Per-cluster maximum total node count for the static accelerator pool. Caps total GPUs at static_accelerator_max_node_count * static_accelerator_count_per_node."
  type        = number
  default     = 8
}

variable "static_accelerator_disk_size_gb" {
  description = "Boot disk size for static accelerator nodes. Large enough to cache the vLLM image plus the Llama 3.1 8B base + LoRA adapters."
  type        = number
  default     = 200
}

variable "static_accelerator_reservation" {
  description = "Optional Compute Engine reservation name to consume for the static accelerator pool. Strongly recommended for Blackwell (g4-*) — RTX PRO 6000 capacity is scarce and pool creation typically fails without a reservation. Leave empty to attempt on-demand."
  type        = string
  default     = ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Other knobs
# ─────────────────────────────────────────────────────────────────────────────

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
