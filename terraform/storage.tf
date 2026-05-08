# GCS buckets the demo workloads read/write at runtime.
#
# - model-weights: vLLM pulls Llama-3.1-8B-Instruct + LoRA adapters from here
#   via runai_streamer (workers/gpu-deployment.yaml).
# - pod-snapshots-<region>: GKE Pod Snapshot writes vLLM checkpoints here
#   (workers/pod-snapshot.yaml). One per worker region so the snapshot is
#   colocated with the cluster reading it.

resource "google_storage_bucket" "model_weights" {
  name                        = "${var.project_id}-model-weights"
  project                     = var.project_id
  location                    = var.model_weights_location
  uniform_bucket_level_access = true
  force_destroy               = true

  versioning {
    enabled = false
  }

  depends_on = [google_project_service.default]
}

resource "google_storage_bucket" "pod_snapshots" {
  for_each = toset(var.worker_regions)

  # First worker region keeps the historical bare bucket name; additional regions
  # get a suffix. Matches the existing live buckets in kubecon-fleets-demo-1.
  name = each.value == var.worker_regions[0] ? "${var.project_id}-pod-snapshots" : "${var.project_id}-pod-snapshots-${replace(each.value, "us-", "")}"

  project                     = var.project_id
  location                    = upper(each.value)
  uniform_bucket_level_access = true
  force_destroy               = true

  depends_on = [google_project_service.default]
}
