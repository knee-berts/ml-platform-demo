resource "google_project_service" "default" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
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
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "default" {
  project_id = var.project_id

  depends_on = [google_project_service.default]
}
