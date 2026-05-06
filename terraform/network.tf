# The demo runs on the auto-mode "default" VPC. Each cluster region gets a
# GLOBAL_MANAGED_PROXY subnet for the multi-cluster Gateway envoy fleet.

data "google_compute_network" "default" {
  name    = "default"
  project = var.project_id

  depends_on = [google_project_service.default]
}

locals {
  # Union of management region + worker regions so we provision one proxy
  # subnet per distinct region the Gateway resolves into.
  all_regions = sort(distinct(concat([var.region], var.worker_regions)))
}

resource "google_compute_subnetwork" "proxy_subnet" {
  for_each = { for idx, r in local.all_regions : r => idx }

  name          = "proxy-subnet-${each.key}"
  project       = var.project_id
  region        = each.key
  network       = data.google_compute_network.default.id
  ip_cidr_range = cidrsubnet("10.4.0.0/16", 7, each.value)
  purpose       = "GLOBAL_MANAGED_PROXY"
  role          = "ACTIVE"
}
