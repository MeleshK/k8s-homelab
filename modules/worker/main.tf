resource "proxmox_virtual_environment_vm" "worker" {
  count     = var.worker_count
  name      = "k8s-worker-${count.index + 1}"
  node_name = var.proxmox_node
  vm_id     = 201 + count.index

  clone { vm_id = var.template_id; full = true }

  cpu    { cores = var.worker.cores; type = "x86-64-v2-AES" }
  memory { dedicated = var.worker.memory }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = var.worker.disk
    discard      = "on"
    iothread     = true
  }

  network_device { bridge = "vmbr0"; model = "virtio" }

  initialization {
    ip_config {
      ipv4 { address = "dhcp" }  # your router hands out IPs
    }
    dns { servers = ["10.0.0.1", "8.8.8.8"] }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
    user_data_file_id = proxmox_virtual_environment_file.bootstrap_cloud_init.id
  }

  agent { enabled = true }
}