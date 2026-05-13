# Workload Identity service accounts the in-cluster workloads bind to.
#
# - sa-inference: bound to the vllm K8s SA in inference-server. Reads from the
#   model-weights bucket.
# - sa-pod-snapshot: bound to the vllm-snapshot-sa K8s SA in inference-server.
#   Writes pod snapshots to the per-region buckets.

resource "google_service_account" "inference" {
  project      = var.project_id
  account_id   = "sa-inference"
  display_name = "Workload Identity SA for vLLM inference pods (model-weights reader)"

  depends_on = [google_project_service.default]
}

resource "google_service_account" "pod_snapshot" {
  project      = var.project_id
  account_id   = "sa-pod-snapshot"
  display_name = "Workload Identity SA for GKE Pod Snapshot (writes vLLM checkpoints)"

  depends_on = [google_project_service.default]
}

# Inference SA → model-weights bucket. Two grants:
# - objectViewer:    read object data (the actual model files)
# - legacyBucketReader: bucket-metadata get. vLLM's runai_streamer calls
#   bucket.reload() during model load, which hits GET /b/<name>?projection=noAcl
#   and that needs storage.buckets.get — not granted by objectViewer/objectUser.
resource "google_storage_bucket_iam_member" "inference_reads_model_weights" {
  for_each = toset([
    "roles/storage.objectViewer",
    "roles/storage.legacyBucketReader",
  ])

  bucket = google_storage_bucket.model_weights.name
  role   = each.value
  member = "serviceAccount:${google_service_account.inference.email}"
}

# Pod-snapshot SA → pod-snapshots-<region> buckets (read+write+create).
resource "google_storage_bucket_iam_member" "pod_snapshot_writes" {
  for_each = google_storage_bucket.pod_snapshots

  bucket = each.value.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.pod_snapshot.email}"
}

# Workload Identity bindings — let the in-cluster KSAs impersonate the GSAs.
# K8s SA names match the manifests in workers/.
resource "google_service_account_iam_member" "inference_wi" {
  service_account_id = google_service_account.inference.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[inference-server/vllm-llama3-8b-instruct]"
}

resource "google_service_account_iam_member" "pod_snapshot_wi" {
  service_account_id = google_service_account.pod_snapshot.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[inference-server/vllm-snapshot-sa]"
}
