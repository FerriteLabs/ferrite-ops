# Common variables shared across Ferrite Terraform modules.

variable "ferrite_version" {
  description = "Ferrite Docker image tag"
  type        = string
  default     = "0.4.0"
}

variable "ferrite_image" {
  description = "Ferrite Docker image repository"
  type        = string
  default     = "ghcr.io/ferritelabs/ferrite"
}

variable "ferrite_port" {
  description = "Ferrite server port"
  type        = number
  default     = 6379
}

variable "metrics_port" {
  description = "Prometheus metrics port"
  type        = number
  default     = 9090
}

variable "max_memory" {
  description = "Maximum memory for Ferrite (e.g. '1GB', '4GB')"
  type        = string
  default     = "1GB"
}

variable "enable_tls" {
  description = "Enable TLS encryption"
  type        = bool
  default     = false
}

variable "enable_persistence" {
  description = "Enable AOF persistence"
  type        = bool
  default     = true
}

variable "aof_fsync" {
  description = "AOF fsync policy: always, everysec, or no"
  type        = string
  default     = "everysec"

  validation {
    condition     = contains(["always", "everysec", "no"], var.aof_fsync)
    error_message = "aof_fsync must be one of: always, everysec, no"
  }
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
