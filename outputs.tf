# Step 1: Wait for control plane cloud-init
resource "null_resource" "wait_control_plane" {
  depends_on = [proxmox_virtual_environment_vm.control_plane]
  triggers   = { vm_id = proxmox_virtual_environment_vm.control_plane[0].id }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = local.cp_ips[0]
      user        = local.ssh_user
      private_key = file(pathexpand("~/.ssh/id_ed25519"))
      host_key    = ""
      timeout     = "15m"
    }
    inline = ["cloud-init status --wait; true"]
  }
}

# Step 2: kubeadm init + Calico + save worker join command
resource "null_resource" "init_cp" {
  depends_on = [null_resource.wait_control_plane]
  triggers   = { vm_id = proxmox_virtual_environment_vm.control_plane[0].id }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = local.cp_ips[0]
      user        = local.ssh_user
      private_key = file(pathexpand("~/.ssh/id_ed25519"))
      host_key    = ""
      timeout     = "20m"
    }
    inline = [
      "set -o pipefail && sudo kubeadm init --pod-network-cidr=${var.pod_cidr} --apiserver-advertise-address=${local.cp_ips[0]} --node-name=k8s-cp-1 2>&1 | sudo tee /var/log/kubeadm-init.log",

      "mkdir -p /home/${local.ssh_user}/.kube",
      "sudo cp /etc/kubernetes/admin.conf /home/${local.ssh_user}/.kube/config",
      "sudo chown ${local.ssh_user}:${local.ssh_user} /home/${local.ssh_user}/.kube/config",

      "kubectl --kubeconfig=/home/${local.ssh_user}/.kube/config create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml",
      "kubectl --kubeconfig=/home/${local.ssh_user}/.kube/config apply -f /tmp/calico-installation.yaml",

      "sudo kubeadm token create --print-join-command | sudo tee /tmp/kubeadm-join-worker.sh",
    ]
  }
}

# Step 3: Fetch worker join command to local machine (with retry)
resource "null_resource" "fetch_join_command" {
  depends_on = [null_resource.init_cp]
  triggers   = { vm_id = proxmox_virtual_environment_vm.control_plane[0].id }

  provisioner "local-exec" {
    command = <<-EOF
      for i in $(seq 1 12); do
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
          -i ~/.ssh/id_ed25519 \
          ${local.ssh_user}@${local.cp_ips[0]} \
          'cat /tmp/kubeadm-join-worker.sh' > /tmp/kubeadm-join-worker.sh \
          && [ -s /tmp/kubeadm-join-worker.sh ] \
          && exit 0
        echo "Attempt $i failed, retrying in 10s..."
        sleep 10
      done
      echo "ERROR: could not fetch join command after 12 attempts"
      exit 1
    EOF
  }
}

# Step 4: Join workers
resource "null_resource" "join_workers" {
  count = var.worker_count
  depends_on = [
    null_resource.fetch_join_command,
    proxmox_virtual_environment_vm.worker,
  ]
  triggers = { vm_id = proxmox_virtual_environment_vm.worker[count.index].id }

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
    source      = "/tmp/kubeadm-join-worker.sh"
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

output "control_plane_ip" { value = local.cp_ips[0] }
output "worker_ips" {
  value = [for ip in var.worker_ips : split("/", ip)[0]]
}
