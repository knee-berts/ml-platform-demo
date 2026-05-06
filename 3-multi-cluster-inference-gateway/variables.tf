variable "project_id" {
  description = "GCP project ID hosting the demo. Must match the value used by the 1-infrastructure stack (terraform/)."
  type        = string
}

variable "region" {
  description = "Region for the google provider. Defaults to the management cluster's region."
  type        = string
  default     = "us-east1"
}

variable "infra_state_path" {
  description = "Local path to the 1-infrastructure (terraform/) state file."
  type        = string
  default     = "../terraform/terraform.tfstate"
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

variable "scale_from_zero_worker_indexes" {
  description = "Indexes (into the worker_clusters output) that should get the scale-from-zero HPA profile. Other workers get the baseline HPA. Defaults to [1] which gives the second worker (us-west3 by default) the spillover behavior described in kueue/hpa-inference-west3.yaml."
  type        = list(number)
  default     = [1]
}
