variable "proxmox_api_url" {
  type = string
}

variable "proxmox_user" {
  type = string
}

variable "proxmox_password" {
  type      = string
  sensitive = true
}

variable "proxmox_node" {
  type    = string
  default = "pve"
}

variable "template_id" {
  type    = number
  default = 9000
}

variable "ssh_public_key" {
  type = string
}

variable "worker_count" {
  type    = number
  default = 2
}

variable "control_plane" {
  type = object({
    cores  = number
    memory = number
    disk   = number
    ip     = string
    gw     = string
  })
  default = {
    cores  = 2
    memory = 4096
    disk   = 30
    ip     = "10.0.0.40/24"
    gw     = "10.0.0.1"
  }
}

variable "os_type" {
  type    = string
  default = "rocky"
  validation {
    condition     = contains(["ubuntu", "rocky"], var.os_type)
    error_message = "os_type must be 'ubuntu' or 'rocky'."
  }
}

variable "k8s_version" {
  type    = string
  default = "1.32"
}

variable "pod_cidr" {
  type    = string
  default = "10.244.0.0/16"
}

variable "worker" {
  type = object({
    cores  = number
    memory = number
    disk   = number
  })
  default = {
    cores  = 2
    memory = 4096
    disk   = 30
  }
}