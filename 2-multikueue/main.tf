provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_client_config" "default" {}

# Read cluster connection details from the 1-infrastructure stack.
data "terraform_remote_state" "infra" {
  backend = "local"
  config = {
    path = var.infra_state_path
  }
}

locals {
  hub     = data.terraform_remote_state.infra.outputs.hub_cluster
  workers = data.terraform_remote_state.infra.outputs.worker_clusters

  use_custom_kueue_image = var.kueue_manager_image_repository != ""

  # Kueue manager config — same shape as upstream's controller-manager-config.yaml,
  # plus the multiKueue clusterProfile block when running on the manager cluster.
  hub_manager_config = yamlencode({
    apiVersion = "config.kueue.x-k8s.io/v1beta2"
    kind       = "Configuration"
    health = {
      healthProbeBindAddress = ":8081"
    }
    metrics = {
      bindAddress = ":8443"
    }
    webhook = {
      port = 9443
    }
    leaderElection = {
      leaderElect  = true
      resourceName = "c1f6bfd2.kueue.x-k8s.io"
    }
    controller = {
      groupKindConcurrency = {
        "Job.batch"                     = 5
        "Pod"                           = 5
        "Workload.kueue.x-k8s.io"       = 5
        "LocalQueue.kueue.x-k8s.io"     = 1
        "ClusterQueue.kueue.x-k8s.io"   = 1
        "ResourceFlavor.kueue.x-k8s.io" = 1
      }
    }
    clientConnection = {
      qps   = 50
      burst = 100
    }
    integrations = {
      frameworks = [
        "batch/job",
        "jobset.x-k8s.io/jobset",
        "leaderworkerset.x-k8s.io/leaderworkerset",
      ]
    }
    featureGates = {
      MultiKueueClusterProfile = true
    }
    multiKueue = {
      dispatcherName = "least-disruption-dispatcher"
      clusterProfile = {
        credentialsProviders = [
          {
            name = "google"
            execConfig = {
              apiVersion      = "client.authentication.k8s.io/v1beta1"
              command         = "/plugins/gcp-auth-plugin"
              interactiveMode = "Never"
            }
          }
        ]
      }
    }
  })
}

# ─── Helm providers ─────────────────────────────────────────────────────────
# One helm provider per cluster. The hub provider is the default; workers are
# aliased. All use the access token of the local gcloud credential.

provider "helm" {
  kubernetes = {
    host                   = "https://${local.hub.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(local.hub.ca_cert)
  }
}

provider "helm" {
  alias = "worker0"
  kubernetes = {
    host                   = "https://${local.workers[0].endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(local.workers[0].ca_cert)
  }
}

provider "helm" {
  alias = "worker1"
  kubernetes = {
    host                   = "https://${local.workers[1].endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(local.workers[1].ca_cert)
  }
}

# Hub kubernetes provider — used to write the worker-<short>-kubeconfig
# Secrets that the least-disruption-dispatcher reads at startup
# (dispatcher/pkg/cluster/client.go::buildRestConfigFromSecret).
provider "kubernetes" {
  host                   = "https://${local.hub.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(local.hub.ca_cert)
}

# ─── JobSet (all clusters) ──────────────────────────────────────────────────
# Required for training-jobset.yaml. Kueue's JobSet integration depends on
# the JobSet CRD existing.

resource "helm_release" "jobset_hub" {
  name             = "jobset"
  namespace        = "jobset-system"
  create_namespace = true
  repository       = "oci://registry.k8s.io/jobset/charts"
  chart            = "jobset"
  version          = var.jobset_version
}

resource "helm_release" "jobset_worker0" {
  provider         = helm.worker0
  name             = "jobset"
  namespace        = "jobset-system"
  create_namespace = true
  repository       = "oci://registry.k8s.io/jobset/charts"
  chart            = "jobset"
  version          = var.jobset_version
}

resource "helm_release" "jobset_worker1" {
  provider         = helm.worker1
  name             = "jobset"
  namespace        = "jobset-system"
  create_namespace = true
  repository       = "oci://registry.k8s.io/jobset/charts"
  chart            = "jobset"
  version          = var.jobset_version
}

# ─── LeaderWorkerSet (optional, all clusters) ───────────────────────────────

resource "helm_release" "lws_hub" {
  count            = var.enable_leaderworkerset ? 1 : 0
  name             = "lws"
  namespace        = "lws-system"
  create_namespace = true
  repository       = "oci://registry.k8s.io/lws/charts"
  chart            = "lws"
  version          = var.leaderworkerset_version
}

resource "helm_release" "lws_worker0" {
  count            = var.enable_leaderworkerset ? 1 : 0
  provider         = helm.worker0
  name             = "lws"
  namespace        = "lws-system"
  create_namespace = true
  repository       = "oci://registry.k8s.io/lws/charts"
  chart            = "lws"
  version          = var.leaderworkerset_version
}

resource "helm_release" "lws_worker1" {
  count            = var.enable_leaderworkerset ? 1 : 0
  provider         = helm.worker1
  name             = "lws"
  namespace        = "lws-system"
  create_namespace = true
  repository       = "oci://registry.k8s.io/lws/charts"
  chart            = "lws"
  version          = var.leaderworkerset_version
}

# ─── Kueue (all clusters) ───────────────────────────────────────────────────
# Hub uses a custom image when kueue_manager_image_repository is set so the
# gcp-auth-plugin is available at /plugins/gcp-auth-plugin for MultiKueue
# ClusterProfile credentialsProviders.

resource "helm_release" "kueue_hub" {
  name             = "kueue"
  namespace        = "kueue-system"
  create_namespace = true
  repository       = "oci://registry.k8s.io/kueue/charts"
  chart            = "kueue"
  version          = var.kueue_version
  wait             = true

  values = [
    yamlencode(merge(
      {
        managerConfig = {
          controllerManagerConfigYaml = local.hub_manager_config
        }
      },
      local.use_custom_kueue_image ? {
        controllerManager = {
          manager = {
            image = {
              repository = var.kueue_manager_image_repository
              tag        = var.kueue_manager_image_tag != "" ? var.kueue_manager_image_tag : var.kueue_version
              pullPolicy = "IfNotPresent"
            }
          }
        }
      } : {}
    ))
  ]

  depends_on = [helm_release.jobset_hub]
}

resource "helm_release" "kueue_worker0" {
  provider         = helm.worker0
  name             = "kueue"
  namespace        = "kueue-system"
  create_namespace = true
  repository       = "oci://registry.k8s.io/kueue/charts"
  chart            = "kueue"
  version          = var.kueue_version

  depends_on = [helm_release.jobset_worker0]
}

resource "helm_release" "kueue_worker1" {
  provider         = helm.worker1
  name             = "kueue"
  namespace        = "kueue-system"
  create_namespace = true
  repository       = "oci://registry.k8s.io/kueue/charts"
  chart            = "kueue"
  version          = var.kueue_version

  depends_on = [helm_release.jobset_worker1]
}

# ─── Demo Kueue resources ───────────────────────────────────────────────────
# kueue-config installs the priority classes, resource flavor, cluster queue,
# and local queues. is_manager toggles between the management spec (16 GPU
# quota + multikueue-check admission check) and the worker spec (8 GPU quota,
# no admission check).

resource "helm_release" "kueue_config_hub" {
  name             = "kueue-config"
  namespace        = "kueue-system"
  create_namespace = false
  chart            = "${path.module}/charts/kueue-config"

  values = [yamlencode({
    isManager                = true
    flavorName               = var.gpu_resource_flavor_name
    nodeLabels               = var.gpu_node_label
    nominalGpuQuota          = 16
    inferenceServerNamespace = "inference-server"
    trainingNamespace        = "training-jobs"
  })]

  depends_on = [helm_release.kueue_hub]
}

resource "helm_release" "kueue_config_worker0" {
  provider         = helm.worker0
  name             = "kueue-config"
  namespace        = "kueue-system"
  create_namespace = false
  chart            = "${path.module}/charts/kueue-config"

  values = [yamlencode({
    isManager                = false
    flavorName               = var.gpu_resource_flavor_name
    nodeLabels               = var.gpu_node_label
    nominalGpuQuota          = 8
    inferenceServerNamespace = "inference-server"
    trainingNamespace        = "training-jobs"
  })]

  depends_on = [helm_release.kueue_worker0]
}

resource "helm_release" "kueue_config_worker1" {
  provider         = helm.worker1
  name             = "kueue-config"
  namespace        = "kueue-system"
  create_namespace = false
  chart            = "${path.module}/charts/kueue-config"

  values = [yamlencode({
    isManager                = false
    flavorName               = var.gpu_resource_flavor_name
    nodeLabels               = var.gpu_node_label
    nominalGpuQuota          = 8
    inferenceServerNamespace = "inference-server"
    trainingNamespace        = "training-jobs"
  })]

  depends_on = [helm_release.kueue_worker1]
}

# ─── MultiKueue control plane (hub only) ────────────────────────────────────

resource "helm_release" "multikueue_control_plane" {
  name             = "multikueue-control-plane"
  namespace        = "kueue-system"
  create_namespace = false
  chart            = "${path.module}/charts/multikueue-control-plane"

  values = [yamlencode({
    workers = [
      for idx, c in local.workers : {
        # MultiKueueCluster name used in MultiKueueConfig.spec.clusters
        multikueueClusterName = "worker-${replace(c.location, "us-", "")}-cluster"
        # ClusterProfile name as registered by fleet-clusterinventory:
        # <cluster-name>-<location>
        clusterProfileName = "${c.name}-${c.location}"
        # Friendly display name for the standalone ClusterProfile fallback (mirrors clusterprofile-west3.yaml)
        displayName = c.name
        # Stable shortname used for the standalone ClusterProfile name (mirrors `worker-west3` in clusterprofile-west3.yaml)
        shortName = "worker-${replace(c.location, "us-", "")}"
        # Tiebreaker priority for the least-disruption-dispatcher. Falls back
        # to var.dispatcher_cluster_priorities[shortName] when set, else 0.
        dispatcherPriority = lookup(var.dispatcher_cluster_priorities, "worker-${replace(c.location, "us-", "")}", 0)
      }
    ]
  })]

  depends_on = [helm_release.kueue_config_hub]
}

# ─── Worker kubeconfig Secrets (hub only) ───────────────────────────────────
# The least-disruption-dispatcher resolves worker connections by reading
# Secrets named worker-<short>-kubeconfig in kueue-system on the hub. The
# kubeconfig points at the worker master directly with the gcp-auth-plugin
# exec credential provider; the plugin mints a Google token from the
# dispatcher pod's Workload Identity (see iam.tf::least_disruption_dispatcher
# in the foundation stack for the IAM bindings that authorize those tokens).

resource "kubernetes_secret_v1" "worker_kubeconfig" {
  for_each = {
    for c in local.workers :
    "worker-${replace(c.location, "us-", "")}" => c
  }

  metadata {
    name      = "${each.key}-kubeconfig"
    namespace = "kueue-system"
  }

  type = "Opaque"

  data = {
    kubeconfig = yamlencode({
      apiVersion      = "v1"
      kind            = "Config"
      current-context = each.key
      clusters = [{
        name = each.key
        cluster = {
          server                     = "https://${each.value.endpoint}"
          certificate-authority-data = each.value.ca_cert
        }
      }]
      contexts = [{
        name = each.key
        context = {
          cluster = each.key
          user    = "google"
        }
      }]
      users = [{
        name = "google"
        user = {
          exec = {
            apiVersion         = "client.authentication.k8s.io/v1beta1"
            command            = "/plugins/gcp-auth-plugin"
            interactiveMode    = "Never"
            provideClusterInfo = true
          }
        }
      }]
    })
  }

  depends_on = [helm_release.kueue_hub]
}

# ─── least-disruption-dispatcher (hub only) ─────────────────────────────────

resource "helm_release" "dispatcher" {
  count = var.enable_dispatcher ? 1 : 0

  name             = "least-disruption-dispatcher"
  namespace        = "kueue-system"
  create_namespace = false
  chart            = "${path.module}/charts/dispatcher"

  values = [yamlencode({
    image              = var.dispatcher_image
    gcpAuthPluginImage = var.gcp_auth_plugin_image
    flavorName         = var.gpu_resource_flavor_name
    clusterQueueName   = "gpu-cluster-queue"
  })]

  depends_on = [
    helm_release.multikueue_control_plane,
    kubernetes_secret_v1.worker_kubeconfig,
  ]
}
