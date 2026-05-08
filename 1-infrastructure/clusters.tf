# ─────────────────────────────────────────────────────────────────────────────
# Locals — derive accelerator type + disk type from the chosen machine type.
# ─────────────────────────────────────────────────────────────────────────────

locals {
  static_accelerator_enabled = var.static_accelerator_machine_type != ""

  # Map machine-type prefix → guest accelerator type and the gke-accelerator
  # node label the inference manifests select on.
  accelerator_type_by_prefix = {
    "g4" = "nvidia-rtx-pro-6000"
    "g2" = "nvidia-l4"
  }

  static_accelerator_prefix = local.static_accelerator_enabled ? split("-", var.static_accelerator_machine_type)[0] : ""
  static_accelerator_type   = local.static_accelerator_enabled ? local.accelerator_type_by_prefix[local.static_accelerator_prefix] : ""

  # g4 (Blackwell) only supports hyperdisk-balanced; g2 (L4) uses pd-balanced.
  static_accelerator_disk_type = local.static_accelerator_prefix == "g4" ? "hyperdisk-balanced" : "pd-balanced"
}

# ─────────────────────────────────────────────────────────────────────────────
# Management cluster — Standard (NOT Autopilot). Hosts the multi-cluster
# Gateway, HTTPRoute, Kueue/MultiKueue control plane. No GPUs.
#
# The fleet { project = ... } block auto-registers the cluster as a member of
# the project's Fleet (created explicitly by google_gke_hub_fleet.default in
# fleet.tf). The two `fleet-clusterinventory-*` resource_labels designate this
# cluster as the inventory manager — fleet-clusterinventory then auto-creates
# ClusterProfile resources in the kueue-system namespace for every fleet
# member, which MultiKueueCluster references via clusterProfileRef.
# ─────────────────────────────────────────────────────────────────────────────

resource "google_container_cluster" "management" {
  name     = var.management_cluster_name
  project  = var.project_id
  location = var.region

  # Standard cluster: drop the auto-created default pool and add our own.
  remove_default_node_pool = true
  initial_node_count       = 1

  fleet {
    project = var.project_id
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = var.release_channel
  }

  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS", "APISERVER", "SCHEDULER", "CONTROLLER_MANAGER",
      "STORAGE", "HPA", "POD", "DAEMONSET", "DEPLOYMENT", "STATEFULSET",
      "KUBELET", "CADVISOR", "DCGM", "JOBSET",
    ]
    managed_prometheus {
      enabled = true
      auto_monitoring_config {
        scope = "ALL"
      }
    }
  }

  resource_labels = {
    fleet-clusterinventory-management-cluster = "true"
    fleet-clusterinventory-namespace          = "kueue-system"
  }

  deletion_protection = false

  depends_on = [
    google_project_service.default,
    google_project_iam_member.clusters,
    google_compute_subnetwork.proxy_subnet,
    google_gke_hub_fleet.default,
  ]
}

resource "google_container_node_pool" "management_default" {
  name     = "${google_container_cluster.management.name}-default-pool"
  project  = var.project_id
  location = google_container_cluster.management.location
  cluster  = google_container_cluster.management.name

  autoscaling {
    total_min_node_count = var.management_min_node_count
    total_max_node_count = var.management_max_node_count
    location_policy      = "BALANCED"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.management_machine_type
    service_account = google_service_account.clusters["management"].email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    disk_size_gb    = var.management_disk_size_gb
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"

    gcfs_config {
      enabled = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  lifecycle {
    ignore_changes = [
      node_count,
    ]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Worker clusters — Standard. Hold vLLM Deployments, EPP, InferencePool,
# InferenceObjective, and the worker side of MultiKueue. Fleet-registered.
#
# Default mode (happy path): no fixed GPU pool. The inference-gpu ComputeClass
# drives Node Auto-Provisioning to create L4 (g2-standard-12) Spot or
# on-demand pools when GPUs are needed, and lets the cluster autoscaler drain
# them between demo runs.
#
# Heavy mode: set var.static_accelerator_machine_type and a fixed accelerator
# pool is attached to every worker (see google_container_node_pool.static_accelerator).
# ─────────────────────────────────────────────────────────────────────────────

resource "google_container_cluster" "workers" {
  for_each = toset(var.worker_regions)

  name     = "ai-worker-${each.value}"
  project  = var.project_id
  location = each.value

  fleet {
    project = var.project_id
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = var.release_channel
  }

  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    service_account = google_service_account.clusters["worker"].email
    gcfs_config {
      enabled = true
    }
  }

  # NAP backs the L4 Spot / L4 on-demand priorities of the inference-gpu
  # ComputeClass. Even when a static accelerator pool is attached, NAP stays
  # on so non-GPU system workloads can still scale.
  cluster_autoscaling {
    enabled             = true
    autoscaling_profile = "OPTIMIZE_UTILIZATION"

    resource_limits {
      resource_type = "cpu"
      minimum       = 0
      maximum       = var.nap_cpu_max
    }
    resource_limits {
      resource_type = "memory"
      minimum       = 0
      maximum       = var.nap_memory_max_gb
    }
    resource_limits {
      resource_type = "nvidia-l4"
      minimum       = 0
      maximum       = var.nap_l4_max_count
    }

    auto_provisioning_defaults {
      service_account = google_service_account.clusters["worker"].email
      oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
      image_type      = "COS_CONTAINERD"
      disk_size       = var.static_accelerator_disk_size_gb
      disk_type       = "pd-balanced"

      management {
        auto_repair  = true
        auto_upgrade = true
      }
    }
  }

  monitoring_config {
    enable_components = [
      "SYSTEM_COMPONENTS", "APISERVER", "SCHEDULER", "CONTROLLER_MANAGER",
      "STORAGE", "HPA", "POD", "DAEMONSET", "DEPLOYMENT", "STATEFULSET",
      "KUBELET", "CADVISOR", "DCGM", "JOBSET",
    ]
    managed_prometheus {
      enabled = true
      auto_monitoring_config {
        scope = "ALL"
      }
    }
  }

  resource_labels = {
    environment = "demo"
  }

  deletion_protection = false

  depends_on = [
    google_project_service.default,
    google_project_iam_member.clusters,
    google_compute_subnetwork.proxy_subnet,
    google_gke_hub_fleet.default,
  ]

  # The demo scripts patch ClusterQueue quotas and other in-cluster state at
  # runtime; ignoring drift from those is consistent with the upstream pattern
  # and avoids fighting demo-time mutations on plan/apply.
  lifecycle {
    ignore_changes = [
      node_config,
      initial_node_count,
      resource_labels,
    ]
  }
}

# Generic system / non-GPU pool for each worker — small, autoscaled. Carries
# control-plane workloads (EPP, kube-system add-ons, dispatcher pods) so they
# don't compete with the GPU pool for placement.
resource "google_container_node_pool" "worker_default" {
  for_each = google_container_cluster.workers

  name     = "${each.value.name}-default-pool"
  project  = var.project_id
  location = each.value.location
  cluster  = each.value.name

  autoscaling {
    total_min_node_count = 1
    total_max_node_count = 4
    location_policy      = "BALANCED"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = "e2-standard-4"
    service_account = google_service_account.clusters["worker"].email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    disk_size_gb    = 100
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"

    gcfs_config {
      enabled = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  lifecycle {
    ignore_changes = [
      node_count,
    ]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Static accelerator node pool (opt-in, heavy mode).
#
# Created only when var.static_accelerator_machine_type is non-empty. Accelerator
# type is inferred from the machine-type prefix:
#
#   g4-* → Blackwell (nvidia-rtx-pro-6000)
#   g2-* → L4        (nvidia-l4)
#
# The cluster autoscaler drains this to static_accelerator_min_node_count when
# no GPU workloads are scheduled, supporting the between-demo scale-to-zero
# pattern in demo-preemption.sh::delete_inference_stack.
#
# IMPORTANT: confirm GPU quota in every worker region before enabling. For
# Blackwell pools (g4-*), supply var.static_accelerator_reservation — RTX PRO
# 6000 capacity is scarce and creation typically fails without a reservation.
# ─────────────────────────────────────────────────────────────────────────────

resource "google_container_node_pool" "static_accelerator" {
  for_each = local.static_accelerator_enabled ? google_container_cluster.workers : {}

  name     = "${each.value.name}-${local.static_accelerator_type}-pool"
  project  = var.project_id
  location = each.value.location
  cluster  = each.value.name

  autoscaling {
    total_min_node_count = var.static_accelerator_min_node_count
    total_max_node_count = var.static_accelerator_max_node_count
    location_policy      = "ANY"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.static_accelerator_machine_type
    service_account = google_service_account.clusters["worker"].email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    disk_size_gb    = var.static_accelerator_disk_size_gb
    disk_type       = local.static_accelerator_disk_type
    image_type      = "COS_CONTAINERD"

    guest_accelerator {
      type  = local.static_accelerator_type
      count = var.static_accelerator_count_per_node
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    gcfs_config {
      enabled = true
    }

    # Match the gke-accelerator label the demo manifests select on.
    labels = {
      "cloud.google.com/gke-accelerator" = local.static_accelerator_type
    }

    # Stop non-GPU pods from landing on these expensive nodes.
    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    dynamic "reservation_affinity" {
      for_each = var.static_accelerator_reservation != "" ? [1] : []
      content {
        consume_reservation_type = "SPECIFIC_RESERVATION"
        key                      = "compute.googleapis.com/reservation-name"
        values                   = [var.static_accelerator_reservation]
      }
    }
  }

  # The demo's HPA + cluster autoscaler change node counts at runtime; ignore
  # node_count drift so re-applies don't churn the pool.
  lifecycle {
    ignore_changes = [
      node_count,
      node_config[0].labels,
    ]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Pod Snapshots — enable via `gcloud beta container clusters update`. The
# google/google-beta providers (6.50) don't expose this on
# google_container_cluster yet, so we drive it through gcloud. The update is
# idempotent: re-running on an already-enabled cluster is a no-op.
# ─────────────────────────────────────────────────────────────────────────────

resource "null_resource" "pod_snapshots_management" {
  triggers = {
    cluster_id = google_container_cluster.management.id
  }

  provisioner "local-exec" {
    command = "gcloud beta container clusters update ${google_container_cluster.management.name} --project=${var.project_id} --region=${google_container_cluster.management.location} --enable-pod-snapshots"
  }

  depends_on = [google_container_node_pool.management_default]
}

resource "null_resource" "pod_snapshots_workers" {
  for_each = google_container_cluster.workers

  triggers = {
    cluster_id = each.value.id
  }

  provisioner "local-exec" {
    command = "gcloud beta container clusters update ${each.value.name} --project=${var.project_id} --region=${each.value.location} --enable-pod-snapshots"
  }

  depends_on = [google_container_node_pool.worker_default]
}
