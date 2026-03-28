resource "proxmox_virtual_environment_vm" "control_plane" {
  name      = "k8s-control-plane"
  node_name = var.proxmox_node
  vm_id     = 200

  clone {
    vm_id = var.template_id
    full  = true
  }

  cpu {
    cores = var.control_plane.cores
    type  = "x86-64-v2-AES"
  }

  memory { dedicated = var.control_plane.memory }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = var.control_plane.disk
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # cloud-init — static IP, your SSH key injected
  initialization {
    ip_config {
      ipv4 {
        address = var.control_plane.ip
        gateway = var.control_plane.gw
      }
    }
    dns {
      servers = ["10.0.0.1", "8.8.8.8"]
    }
    user_account {
      username = "mil"
      keys     = [var.ssh_public_key]
    }
    user_data_file_id = proxmox_virtual_environment_file.bootstrap_cloud_init.id
  }

  agent { enabled = true }

  lifecycle {
    ignore_changes = [initialization[0].user_account[0].keys]
  }
}