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

# Step 2: Join each worker — Terraform connects to workers via the control plane
# as a jump host, so only Terraform's key is ever needed
resource "null_resource" "join_workers" {
  count = var.worker_count
  depends_on = [
    null_resource.wait_control_plane,
    proxmox_virtual_environment_vm.worker,
  ]

  # Wait for worker cloud-init
  provisioner "remote-exec" {
    connection {
      type                = "ssh"
      host                = split("/", var.worker_ips[count.index])[0]
      user                = local.ssh_user
      private_key         = file(pathexpand("~/.ssh/id_ed25519"))
      host_key            = ""
      timeout             = "10m"
      bastion_host        = split("/", var.control_plane.ip)[0]
      bastion_user        = local.ssh_user
      bastion_private_key = file(pathexpand("~/.ssh/id_ed25519"))
      bastion_host_key    = ""
    }
    inline = ["cloud-init status --wait"]
  }

  # Copy join command from control plane to worker via Terraform (jump host connection)
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
      "scp -o StrictHostKeyChecking=no /tmp/kubeadm-join.sh ${local.ssh_user}@${split("/", var.worker_ips[count.index])[0]}:/tmp/kubeadm-join.sh"
    ]
  }

  # Run the join on the worker
  provisioner "remote-exec" {
    connection {
      type                = "ssh"
      host                = split("/", var.worker_ips[count.index])[0]
      user                = local.ssh_user
      private_key         = file(pathexpand("~/.ssh/id_ed25519"))
      host_key            = ""
      timeout             = "10m"
      bastion_host        = split("/", var.control_plane.ip)[0]
      bastion_user        = local.ssh_user
      bastion_private_key = file(pathexpand("~/.ssh/id_ed25519"))
      bastion_host_key    = ""
    }
    inline = ["sudo bash /tmp/kubeadm-join.sh --node-name=k8s-worker-${count.index + 1}"]
  }
}

output "control_plane_ip" { value = split("/", var.control_plane.ip)[0] }
output "worker_ips" {
  value = [for ip in var.worker_ips : split("/", ip)[0]]
}
