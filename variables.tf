variable "proxmox_api_url"    { type = string }
variable "proxmox_user"       { type = string }
variable "proxmox_password"   { type = string; sensitive = true }
variable "proxmox_node"       { type = string; default = "pve" }
variable "template_id"        { type = number; default = 9000 }
variable "ssh_public_key"     { type = string }  # contents of ~/.ssh/id_ed25519.pub
variable "worker_count"       { type = number; default = 2 }

variable "control_plane" {
  type = object({
    cores  = number
    memory = number
    disk   = string
    ip     = string  # static: "10.0.0.10/24"
    gw     = string  # "10.0.0.1"
  })
  default = {
    cores  = 2
    memory = 4096
    disk   = "30G"
    ip     = "10.0.0.10/24"
    gw     = "10.0.0.1"
  }
}

variable "worker" {
  type = object({ cores = number; memory = number; disk = string })
  default = { cores = 2; memory = 4096; disk = "30G" }
}