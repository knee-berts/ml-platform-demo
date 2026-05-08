variable "project_id" {
  description = "GCP project ID hosting the demo. Must match the value used by the 1-infrastructure stack (1-infrastructure/)."
  type        = string
}

variable "region" {
  description = "Region for the google provider. Defaults to the management cluster's region."
  type        = string
  default     = "us-east1"
}

variable "infra_state_path" {
  description = "Local path to the 1-infrastructure state file."
  type        = string
  default     = "../1-infrastructure/terraform.tfstate"
}

variable "gateway_name" {
  description = "Name of the multi-cluster Gateway resource on the management cluster."
  type        = string
  default     = "cross-region-gateway"
}

variable "inference_pool_name" {
  description = "InferencePool name. The HTTPRoute backendRef and Deployment app label both reference this."
  type        = string
  default     = "vllm-llama3-8b-instruct"
}

variable "inference_namespace" {
  description = "Namespace that holds the inference Deployment, InferencePool, EPP, etc."
  type        = string
  default     = "inference-server"
}

variable "gateway_namespace" {
  description = "Namespace that holds the multi-cluster Gateway and HTTPRoute."
  type        = string
  default     = "gateway-system"
}

variable "epp_image" {
  description = "EPP container image. v1.4.0 is the first release with flow control + saturation detector + scoring plugins."
  type        = string
  default     = "registry.k8s.io/gateway-api-inference-extension/epp:v1.4.0"
}

variable "kv_cache_threshold_percent" {
  description = "GCPBackendPolicy kv-cache utilization threshold above which the GCLB stops sending traffic to a cluster. The EPP buffers requests above this until KV cache drains."
  type        = number
  default     = 60
}

variable "saturation_kv_cache_util_threshold" {
  description = "EPP saturation detector — pool considered saturated above this KV cache fraction. EPP holds requests rather than flooding GPUs."
  type        = number
  default     = 0.90
}

variable "saturation_queue_depth_threshold" {
  description = "EPP saturation detector — pool considered saturated above this average queue depth. ~10% of vLLM --max-num-seq."
  type        = number
  default     = 100
}

variable "compute_class_name" {
  description = "Name of the GPU ComputeClass selected by the inference Deployment. Must match `cloud.google.com/compute-class` nodeSelector."
  type        = string
  default     = "inference-gpu"
}

variable "enable_blackwell_compute_class_tier" {
  description = "Add a Blackwell (RTX PRO 6000) tier to the ComputeClass priority list. Default false — the demo runs on L4. Enable only if your project has Blackwell quota; align with 1-infrastructure/variables.tf::enable_blackwell_pool."
  type        = bool
  default     = false
}

variable "enable_pod_snapshot" {
  description = "Whether to install GKE Pod Snapshot resources (PodSnapshotPolicy + PodSnapshotStorageConfig + KSA). Set false on clusters where the podsnapshot.gke.io CRDs aren't installed."
  type        = bool
  default     = true
}

variable "vllm_image" {
  description = "vLLM container image. Built by 3-mcig/docker/vllm/cloudbuild.yaml; install.sh sets this to us-east1-docker.pkg.dev/<project>/vllm-blackwell/vllm-blackwell:latest."
  type        = string
}

variable "model_weights_path" {
  description = "Path to Llama 3.1 8B Instruct weights. Default points at the model-weights bucket created by the 1-infrastructure stack and populated by the weights-uploader Cloud Build."
  type        = string
}

variable "served_model_name" {
  description = "Logical model name vLLM serves the weights as. Should match the HuggingFace repo id for compatibility with HuggingFace clients."
  type        = string
  default     = "meta-llama/Llama-3.1-8B-Instruct"
}

variable "hf_token" {
  description = "HuggingFace API token with access to the gated meta-llama/Llama-3.1-8B-Instruct repo. Pass via TF_VAR_hf_token env var; do NOT commit a literal value to a tfvars file."
  type        = string
  sensitive   = true
}

variable "vllm_runtime_class_name" {
  description = "RuntimeClass for the vLLM Deployment (e.g. \"gvisor\"). Empty = no runtimeClass. NAP-created nodes don't have gvisor pre-installed."
  type        = string
  default     = ""
}

variable "vllm_max_num_seq" {
  description = "vLLM --max-num-seq. Default 16 fits Llama 3.1 8B bf16 + fp8 KV cache on L4 (24GB). Bump to 256+ on Blackwell."
  type        = number
  default     = 16
}

variable "vllm_max_model_len" {
  description = "vLLM --max-model-len. Caps context window to bound KV cache size. 2048 is the largest that fits with Llama 3.1 8B + fp8 KV on L4."
  type        = number
  default     = 2048
}

variable "vllm_gpu_memory_utilization" {
  description = "vLLM --gpu-memory-utilization. 0.95 on L4 because Llama 3.1 8B leaves <2 GiB for KV at the default 0.9. Drop back to 0.9 if you see OOMs from the framework's residual allocations."
  type        = number
  default     = 0.95
}

variable "vllm_kv_cache_dtype" {
  description = "vLLM --kv-cache-dtype. Default fp8 halves KV memory (and is required to fit Llama 3.1 8B on L4). Set to \"\" to disable; safe to leave fp8 on Blackwell too."
  type        = string
  default     = "fp8"
}
