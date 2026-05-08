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

  # Stable per-region CIDR allocation. CIDRs MUST NOT depend on the order or
  # contents of var.worker_regions — proxy subnets are referenced by the
  # cross-region Gateway forwarding rules, so changing the CIDR of an existing
  # subnet forces destroy+create which fails as long as the gateway exists.
  # Each entry gets a /23 carved out of 10.4.0.0/16; new regions go to a new
  # offset and never reuse a previous one.
  region_proxy_cidr = {
    "us-east1"    = "10.4.0.0/23"
    "us-west3"    = "10.4.2.0/23"
    "us-central1" = "10.4.4.0/23"
    "us-east4"    = "10.4.6.0/23"
    "us-west1"    = "10.4.8.0/23"
    "us-west4"    = "10.4.10.0/23"
  }
}

resource "google_compute_subnetwork" "proxy_subnet" {
  for_each = toset(local.all_regions)

  name          = "proxy-subnet-${each.key}"
  project       = var.project_id
  region        = each.key
  network       = data.google_compute_network.default.id
  ip_cidr_range = lookup(local.region_proxy_cidr, each.key, null) != null ? local.region_proxy_cidr[each.key] : null
  purpose       = "GLOBAL_MANAGED_PROXY"
  role          = "ACTIVE"

  lifecycle {
    precondition {
      condition     = contains(keys(local.region_proxy_cidr), each.key)
      error_message = "Region '${each.key}' has no entry in local.region_proxy_cidr. Add a stable /23 CIDR for it in network.tf before adding the region to worker_regions."
    }
  }
}
