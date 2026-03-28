locals {
  ssh_user = var.os_type == "rocky" ? "rocky" : "ubuntu"
  cp_script     = var.os_type == "rocky" ? "scripts/control-plane-rocky.sh.tftp1" : "scripts/control-plane.sh.tftp1"
  worker_script = var.os_type == "rocky" ? "scripts/worker-rocky.sh.tftp1" : "scripts/worker.sh.tftp1"
}

resource "proxmox_virtual_environment_file" "control_plane_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/${local.cp_script}", {
      k8s_version      = var.k8s_version
      pod_cidr         = var.pod_cidr
      control_plane_ip = split("/", var.control_plane.ip)[0]
    })
    file_name = "k8s-control-plane-init.yaml"
  }
}

resource "proxmox_virtual_environment_file" "worker_cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/${local.worker_script}", {
      k8s_version = var.k8s_version
    })
    file_name = "k8s-worker-init.yaml"
  }
}

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
      username = local.ssh_user
      keys     = [var.ssh_public_key]
    }
    user_data_file_id = proxmox_virtual_environment_file.control_plane_cloud_init.id
  }

  agent { enabled = true }

  lifecycle {
    ignore_changes = [initialization[0].user_account[0].keys]
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  count     = var.worker_count
  name      = "k8s-worker-${count.index + 1}"
  node_name = var.proxmox_node
  vm_id     = 201 + count.index

  clone {
    vm_id = var.template_id
    full  = true
  }

  cpu {
    cores = var.worker.cores
    type  = "x86-64-v2-AES"
  }
  memory { dedicated = var.worker.memory }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = var.worker.disk
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 { address = "dhcp" }
    }
    dns { servers = ["10.0.0.1", "8.8.8.8"] }
    user_account {
      username = local.ssh_user
      keys     = [var.ssh_public_key]
    }
    user_data_file_id = proxmox_virtual_environment_file.worker_cloud_init.id
  }

  agent { enabled = true }
}
