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

# Step 2: Once control plane is ready, join each worker using the saved join command
resource "null_resource" "join_workers" {
  count = var.worker_count
  depends_on = [
    null_resource.wait_control_plane,
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
    inline = [
      "cloud-init status --wait",
      "ssh -o StrictHostKeyChecking=no ${local.ssh_user}@${split("/", var.control_plane.ip)[0]} 'cat /tmp/kubeadm-join.sh' | sudo bash -s -- --node-name=k8s-worker-$((${count.index} + 1))"
    ]
  }
}

output "control_plane_ip" { value = split("/", var.control_plane.ip)[0] }
output "worker_ips" {
  value = [for ip in var.worker_ips : split("/", ip)[0]]
}
