locals {
  required_services = [
    "cloudresourcemanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "gkehub.googleapis.com",
    "connectgateway.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "trafficdirector.googleapis.com",
    "multiclusteringress.googleapis.com",
    "multiclusterservicediscovery.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "secretmanager.googleapis.com",
  ]
}

# Project services. Toggled off via `manage_project_services = false` when
# the cross-project SA being used can't pass the provider's serviceusage LIST
# refresh check (some Google-internal projects block this even with Owner +
# serviceUsageAdmin). When toggled off, enable the APIs in `local.required_services`
# manually with `gcloud services enable` before running apply.
resource "google_project_service" "default" {
  for_each = var.manage_project_services ? toset(local.required_services) : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "default" {
  project_id = var.project_id

  depends_on = [google_project_service.default]
}
