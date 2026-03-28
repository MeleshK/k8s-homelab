# Step 1: Wait for control-plane cloud-init to complete
resource "null_resource" "wait_control_plane" {
  depends_on = [proxmox_virtual_environment_vm.control_plane]
  triggers   = { cp_ip = var.control_plane.ip }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = split("/", var.control_plane.ip)[0]
      user        = local.ssh_user
      private_key = file(pathexpand("~/.ssh/id_ed25519"))
      host_key    = ""
      timeout     = "10m"
    }
    inline = ["cloud-init status --wait"]
  }
}

# Step 2: Fetch the join command from the control plane to the local machine
resource "null_resource" "fetch_join_command" {
  depends_on = [null_resource.wait_control_plane]
  triggers   = { cp_ip = var.control_plane.ip }

  provisioner "local-exec" {
    command = "ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ${local.ssh_user}@${split("/", var.control_plane.ip)[0]} 'cat /tmp/kubeadm-join.sh' > /tmp/kubeadm-join.sh"
  }
}

# Step 3: Copy join command to each worker and run it
resource "null_resource" "join_workers" {
  count = var.worker_count
  depends_on = [
    null_resource.fetch_join_command,
    proxmox_virtual_environment_vm.worker,
  ]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = split("/", var.worker_ips[count.index])[0]
      user        = local.ssh_user
      private_key = file(pathexpand("~/.ssh/id_ed25519"))
      host_key    = ""
      timeout     = "10m"
    }
    inline = ["cloud-init status --wait"]
  }

  provisioner "file" {
    connection {
      type        = "ssh"
      host        = split("/", var.worker_ips[count.index])[0]
      user        = local.ssh_user
      private_key = file(pathexpand("~/.ssh/id_ed25519"))
      host_key    = ""
      timeout     = "10m"
    }
    source      = "/tmp/kubeadm-join.sh"
    destination = "/tmp/kubeadm-join.sh"
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = split("/", var.worker_ips[count.index])[0]
      user        = local.ssh_user
      private_key = file(pathexpand("~/.ssh/id_ed25519"))
      host_key    = ""
      timeout     = "10m"
    }
    inline = ["sudo bash /tmp/kubeadm-join.sh --node-name=k8s-worker-${count.index + 1}"]
  }
}

output "control_plane_ip" { value = split("/", var.control_plane.ip)[0] }
output "worker_ips" {
  value = [for ip in var.worker_ips : split("/", ip)[0]]
}
