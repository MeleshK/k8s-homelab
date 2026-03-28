resource "null_resource" "init_cluster" {
  depends_on = [
    proxmox_virtual_environment_vm.control_plane,
    proxmox_virtual_environment_vm.worker
  ]

  # Re-runs if the control plane IP changes
  triggers = { cp_ip = var.control_plane.ip }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = "10.0.0.10"
      user        = "ubuntu"
      private_key = file("~/.ssh/id_ed25519")
    }
    inline = [
      # Wait for cloud-init to finish
      "cloud-init status --wait",
      # Init control plane
      "sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=10.0.0.10",
      # Set up kubeconfig
      "mkdir -p $HOME/.kube",
      "sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config",
      "sudo chown $(id -u):$(id -g) $HOME/.kube/config",
      # Install Flannel CNI
      "kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml",
      # Generate join command and stash it
      "sudo kubeadm token create --print-join-command > /tmp/join.sh"
    ]
  }
}

# Fetch the join command from the control plane, run it on each worker
resource "null_resource" "join_workers" {
  count      = var.worker_count
  depends_on = [null_resource.init_cluster]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = proxmox_virtual_environment_vm.worker[count.index].ipv4_addresses[1][0]
      user        = "ubuntu"
      private_key = file("~/.ssh/id_ed25519")
    }
    inline = [
      "cloud-init status --wait",
      # Fetch join command from control plane via SSH proxy
      "ssh -o StrictHostKeyChecking=no ubuntu@10.0.0.10 'cat /tmp/join.sh' | sudo bash"
    ]
  }
}

output "control_plane_ip" { value = var.control_plane.ip }
output "worker_ips" {
  value = [for w in proxmox_virtual_environment_vm.worker : w.ipv4_addresses[1][0]]
}