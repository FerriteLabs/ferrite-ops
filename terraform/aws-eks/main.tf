# Ferrite on AWS EKS via Helm
#
# Deploys Ferrite to an existing EKS cluster using the official Helm chart.
# Configures:
# - Helm release with customizable values
# - Optional HA mode (primary + replicas)
# - Prometheus ServiceMonitor for metrics
# - EBS CSI persistent volumes
# - Kubernetes namespace and RBAC

terraform {
  required_version = ">= 1.5"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "EKS cluster name (used for tagging)"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for Ferrite"
  type        = string
  default     = "ferrite"
}

variable "create_namespace" {
  description = "Create the namespace if it doesn't exist"
  type        = bool
  default     = true
}

variable "ferrite_version" {
  description = "Ferrite application version"
  type        = string
  default     = "0.4.0"
}

variable "chart_version" {
  description = "Helm chart version (defaults to app version)"
  type        = string
  default     = ""
}

variable "replica_count" {
  description = "Number of Ferrite replicas"
  type        = number
  default     = 1
}

variable "storage_size" {
  description = "Persistent volume size"
  type        = string
  default     = "10Gi"
}

variable "storage_class" {
  description = "Kubernetes storage class (e.g. gp3, io2)"
  type        = string
  default     = "gp3"
}

variable "cpu_request" {
  description = "CPU request per pod"
  type        = string
  default     = "500m"
}

variable "cpu_limit" {
  description = "CPU limit per pod"
  type        = string
  default     = "2000m"
}

variable "memory_request" {
  description = "Memory request per pod"
  type        = string
  default     = "1Gi"
}

variable "memory_limit" {
  description = "Memory limit per pod"
  type        = string
  default     = "4Gi"
}

variable "max_memory" {
  description = "Ferrite maxmemory setting"
  type        = string
  default     = "2GB"
}

variable "enable_ha" {
  description = "Enable high availability (primary + replicas with anti-affinity)"
  type        = bool
  default     = false
}

variable "enable_monitoring" {
  description = "Enable Prometheus ServiceMonitor"
  type        = bool
  default     = true
}

variable "enable_tls" {
  description = "Enable TLS with cert-manager"
  type        = bool
  default     = false
}

variable "enable_network_policy" {
  description = "Enable Kubernetes NetworkPolicy"
  type        = bool
  default     = true
}

variable "extra_values" {
  description = "Additional Helm values to merge (YAML string)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Resource tags (applied as Kubernetes labels)"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "ferrite" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace
    labels = merge(var.tags, {
      "app.kubernetes.io/managed-by" = "terraform"
    })
  }
}

# ---------------------------------------------------------------------------
# Helm Release
# ---------------------------------------------------------------------------

resource "helm_release" "ferrite" {
  name       = "ferrite"
  namespace  = var.namespace
  repository = "https://ferritelabs.github.io/ferrite-ops"
  chart      = "ferrite"
  version    = var.chart_version != "" ? var.chart_version : var.ferrite_version

  create_namespace = !var.create_namespace
  wait             = true
  timeout          = 600
  atomic           = true

  values = compact([
    yamlencode({
      image = {
        tag = var.ferrite_version
      }

      replicaCount = var.replica_count

      resources = {
        requests = {
          cpu    = var.cpu_request
          memory = var.memory_request
        }
        limits = {
          cpu    = var.cpu_limit
          memory = var.memory_limit
        }
      }

      persistence = {
        enabled      = true
        size         = var.storage_size
        storageClass = var.storage_class
      }

      ferrite = {
        maxMemory = var.max_memory
        persistence = {
          aof = {
            enabled = true
            fsync   = "everysec"
          }
        }
      }

      metrics = {
        enabled = var.enable_monitoring
        serviceMonitor = {
          enabled = var.enable_monitoring
        }
      }

      tls = {
        enabled = var.enable_tls
        certManager = {
          enabled = var.enable_tls
        }
      }

      networkPolicy = {
        enabled = var.enable_network_policy
      }
    }),

    var.enable_ha ? yamlencode({
      replicaCount = max(var.replica_count, 3)
      replication = {
        enabled = true
      }
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 2
      }
      affinity = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              labelSelector = {
                matchExpressions = [{
                  key      = "app.kubernetes.io/name"
                  operator = "In"
                  values   = ["ferrite"]
                }]
              }
              topologyKey = "kubernetes.io/hostname"
            }
          }]
        }
      }
    }) : "",

    var.extra_values != "" ? var.extra_values : "",
  ])

  depends_on = [kubernetes_namespace.ferrite]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "endpoint" {
  description = "Ferrite service endpoint within the cluster"
  value       = "ferrite.${var.namespace}.svc.cluster.local"
}

output "port" {
  description = "Ferrite port"
  value       = 6379
}

output "namespace" {
  description = "Kubernetes namespace"
  value       = var.namespace
}

output "release_name" {
  description = "Helm release name"
  value       = helm_release.ferrite.name
}

output "release_status" {
  description = "Helm release status"
  value       = helm_release.ferrite.status
}

output "metrics_endpoint" {
  description = "Prometheus metrics endpoint"
  value       = var.enable_monitoring ? "ferrite-metrics.${var.namespace}.svc.cluster.local:9090/metrics" : "monitoring disabled"
}
