# Management cluster (Autopilot) — hosts the multi-cluster Gateway, HTTPRoute,
# Kueue/MultiKueue control plane, and ArgoCD if used. No GPUs here.
resource "google_container_cluster" "management" {
  name             = var.management_cluster_name
  project          = var.project_id
  location         = var.region
  enable_autopilot = true

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

  cluster_autoscaling {
    auto_provisioning_defaults {
      service_account = google_service_account.clusters["management"].email
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
    fleet-clusterinventory-management-cluster = "true"
    fleet-clusterinventory-namespace          = "kueue-system"
  }

  deletion_protection = false

  depends_on = [
    google_project_service.default,
    google_project_iam_member.clusters,
    google_compute_subnetwork.proxy_subnet,
  ]
}

# Worker clusters (Standard) — hold the GPU node pool, vLLM Deployments, EPP,
# and InferencePool/InferenceObjective resources.
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

  # Default node pool is replaced by the GPU pool below; just give it a single
  # small node and remove it after the GPU pool is up if you want to reduce cost.
  initial_node_count       = 1
  remove_default_node_pool = false

  node_config {
    service_account = google_service_account.clusters["worker"].email
    gcfs_config {
      enabled = true
    }
  }

  # Node Auto-Provisioning. The inference-gpu ComputeClass uses NAP to
  # materialize L4 Spot / L4 on-demand pools when Blackwell stocks out.
  # The Blackwell pool itself stays Terraform-managed (see below).
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
      disk_size       = var.gpu_node_disk_size_gb
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

# RTX PRO 6000 Blackwell pool. The cluster autoscaler drains this to
# gpu_node_min_count when no GPU workloads are scheduled, supporting the
# between-demo scale-to-zero pattern in demo-preemption.sh::delete_inference_stack.
resource "google_container_node_pool" "rtx_pro_6000" {
  for_each = google_container_cluster.workers

  name     = "${each.value.name}-rtx-pro-6000-pool"
  project  = var.project_id
  location = each.value.location
  cluster  = each.value.name

  autoscaling {
    total_min_node_count = var.gpu_node_min_count
    total_max_node_count = var.gpu_node_max_count
    location_policy      = "ANY"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.gpu_machine_type
    service_account = google_service_account.clusters["worker"].email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    disk_size_gb    = var.gpu_node_disk_size_gb
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"

    guest_accelerator {
      type  = "nvidia-rtx-pro-6000"
      count = var.gpu_count_per_node
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    gcfs_config {
      enabled = true
    }

    # Match the gke-accelerator label the demo manifests select on.
    labels = {
      "cloud.google.com/gke-accelerator" = "nvidia-rtx-pro-6000"
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
