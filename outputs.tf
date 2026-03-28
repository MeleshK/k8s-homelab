resource "null_resource" "init_cluster" {
  depends_on = [
    proxmox_virtual_environment_vm.control_plane,
    proxmox_virtual_environment_vm.worker
  ]

  # Re-runs if the control plane IP changes
  triggers = { cp_ip = var.control_plane.ip }

  provisioner "remote-exec" {
    connection {
      type                = "ssh"
      host                = split("/", var.control_plane.ip)[0]
      user                = local.ssh_user
      private_key         = file(pathexpand("~/.ssh/id_ed25519"))
      host_key            = ""
      timeout             = "5m"
    }
    inline = [
      # Wait for cloud-init to finish
      "cloud-init status --wait",
      # Init control plane
      "sudo kubeadm init --pod-network-cidr=${var.pod_cidr} --apiserver-advertise-address=${split("/", var.control_plane.ip)[0]}",
      # Set up kubeconfig
      "mkdir -p $HOME/.kube",
      "sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config",
      "sudo chown $(id -u):$(id -g) $HOME/.kube/config",
      # Install Calico CNI via Tigera operator
      "kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml",
      "kubectl apply -f /tmp/calico-installation.yaml",
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
      type                = "ssh"
      host                = proxmox_virtual_environment_vm.worker[count.index].ipv4_addresses[1][0]
      user                = local.ssh_user
      private_key         = file(pathexpand("~/.ssh/id_ed25519"))
      host_key            = ""
      timeout             = "5m"
    }
    inline = [
      "cloud-init status --wait",
      # Fetch join command from control plane via SSH proxy
      "ssh -o StrictHostKeyChecking=no ${local.ssh_user}@${split("/", var.control_plane.ip)[0]} 'cat /tmp/join.sh' | sudo bash"
    ]
  }
}

output "control_plane_ip" { value = var.control_plane.ip }
output "worker_ips" {
  value = [for w in proxmox_virtual_environment_vm.worker : w.ipv4_addresses[1][0]]
}