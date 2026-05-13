output "gateway_namespace" {
  description = "Namespace hosting the multi-cluster Gateway and HTTPRoute on the management cluster."
  value       = var.gateway_namespace
}

output "gateway_name" {
  description = "Multi-cluster Gateway resource name."
  value       = var.gateway_name
}

output "inference_pool_name" {
  description = "Name of the InferencePool exported from each worker. The HTTPRoute backendRef and vLLM Deployment app label both reference this."
  value       = var.inference_pool_name
}

output "inference_namespace" {
  description = "Namespace holding the inference Deployment, EPP, and InferencePool on each worker."
  value       = var.inference_namespace
}

output "compute_class_name" {
  description = "ComputeClass selected by the inference Deployment via cloud.google.com/compute-class."
  value       = var.compute_class_name
}
