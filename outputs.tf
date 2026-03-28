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

# Step 2: Fetch join command to local machine with retry
# (sshd may briefly restart at the end of cloud-init)
resource "null_resource" "fetch_join_command" {
  depends_on = [null_resource.wait_control_plane]
  triggers   = { cp_ip = var.control_plane.ip }

  provisioner "local-exec" {
    command = <<-EOF
      for i in $(seq 1 12); do
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
          -i ~/.ssh/id_ed25519 \
          ${local.ssh_user}@${split("/", var.control_plane.ip)[0]} \
          'cat /tmp/kubeadm-join.sh' > /tmp/kubeadm-join.sh \
          && [ -s /tmp/kubeadm-join.sh ] && exit 0
        echo "Attempt $i failed, retrying in 10s..."
        sleep 10
      done
      echo "ERROR: could not fetch join command after 12 attempts"
      exit 1
    EOF
  }
}

# Step 3: For each worker — wait for cloud-init, copy join script, run it
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
    inline = ["cloud-init status --wait; true"]
  }

  provisioner "file" {
    connection {
      type        = "ssh"
      host        = split("/", var.worker_ips[count.index])[0]
      user        = local.ssh_user
      private_key = file(pathexpand("~/.ssh/id_ed25519"))
      host_key    = ""
      timeout     = "5m"
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
