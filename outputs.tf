# Step 1: Wait for all control plane cloud-inits
resource "null_resource" "wait_control_planes" {
  count      = local.cp_count
  depends_on = [proxmox_virtual_environment_vm.control_plane]
  triggers   = { ip = var.control_plane.ips[count.index] }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = local.cp_ips[count.index]
      user        = local.ssh_user
      private_key = file(pathexpand("~/.ssh/id_ed25519"))
      host_key    = ""
      timeout     = "15m"
    }
    inline = ["cloud-init status --wait; true"]
  }
}

# Step 2: Bootstrap primary CP — kube-vip + kubeadm init + Calico + save join commands
resource "null_resource" "init_primary_cp" {
  depends_on = [null_resource.wait_control_planes]
  triggers   = { ip = var.control_plane.ips[0] }

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
      # Create placeholder admin.conf so kube-vip's volume mount succeeds before kubeadm init
      "sudo mkdir -p /etc/kubernetes/manifests",
      "sudo touch /etc/kubernetes/admin.conf",

      # kube-vip static pod — no --leaderElection on primary so it claims VIP immediately
      # (leader election requires the apiserver, which doesn't exist yet before kubeadm init)
      "IFACE=$(ip route | grep default | awk '{print $5}' | head -1)",
      "sudo ctr image pull ghcr.io/kube-vip/kube-vip:${var.kube_vip_version}",
      "sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${var.kube_vip_version} vip /kube-vip manifest pod --interface $IFACE --address ${var.control_plane.vip} --controlplane --arp | sudo tee /etc/kubernetes/manifests/kube-vip.yaml",

      # Wait for kube-vip to claim the VIP before kubeadm tries to use it
      "echo 'Waiting for kube-vip to claim ${var.control_plane.vip}...' && for i in $(seq 1 30); do ping -c1 -W1 ${var.control_plane.vip} > /dev/null 2>&1 && echo 'VIP is reachable' && break || echo \"Attempt $i: VIP not up yet, waiting 5s...\"; sleep 5; done",

      # kubeadm init
      "sudo kubeadm init --control-plane-endpoint=${var.control_plane.vip}:6443 --pod-network-cidr=${var.pod_cidr} --apiserver-advertise-address=${local.cp_ips[0]} --upload-certs --node-name=k8s-cp-1 2>&1 | sudo tee /var/log/kubeadm-init.log",

      # kubeconfig
      "mkdir -p /home/${local.ssh_user}/.kube",
      "sudo cp /etc/kubernetes/admin.conf /home/${local.ssh_user}/.kube/config",
      "sudo chown ${local.ssh_user}:${local.ssh_user} /home/${local.ssh_user}/.kube/config",

      # Wait for kube-vip to claim the VIP and apiserver to be reachable via it
      "echo 'Waiting for VIP ${var.control_plane.vip}:6443...' && for i in $(seq 1 30); do curl -sk https://${var.control_plane.vip}:6443/healthz | grep -q ok && echo 'VIP ready' && break || echo \"Attempt $i: not ready yet, waiting 5s...\"; sleep 5; done",

      # Calico
      "kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml",
      "kubectl apply -f /tmp/calico-installation.yaml",

      # Worker join command
      "sudo kubeadm token create --print-join-command | sudo tee /tmp/kubeadm-join-worker.sh",

      # CP join command — re-upload certs to avoid 2h expiry during slow applies
      "CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1) && JOIN=$(sudo kubeadm token create --print-join-command) && echo \"$JOIN --control-plane --certificate-key $CERT_KEY\" | sudo tee /tmp/kubeadm-join-cp.sh",
    ]
  }
}

# Step 3: Fetch both join commands to local machine (with retry)
resource "null_resource" "fetch_join_commands" {
  depends_on = [null_resource.init_primary_cp]
  triggers   = { ip = var.control_plane.ips[0] }

  provisioner "local-exec" {
    command = <<-EOF
      for i in $(seq 1 12); do
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
          -i ~/.ssh/id_ed25519 \
          ${local.ssh_user}@${local.cp_ips[0]} \
          'cat /tmp/kubeadm-join-worker.sh' > /tmp/kubeadm-join-worker.sh \
          && [ -s /tmp/kubeadm-join-worker.sh ] \
          && ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
          -i ~/.ssh/id_ed25519 \
          ${local.ssh_user}@${local.cp_ips[0]} \
          'cat /tmp/kubeadm-join-cp.sh' > /tmp/kubeadm-join-cp.sh \
          && [ -s /tmp/kubeadm-join-cp.sh ] \
          && exit 0
        echo "Attempt $i failed, retrying in 10s..."
        sleep 10
      done
      echo "ERROR: could not fetch join commands after 12 attempts"
      exit 1
    EOF
  }
}

# Step 4: Join secondary control planes
resource "null_resource" "join_secondary_cps" {
  count      = local.cp_count - 1
  depends_on = [null_resource.fetch_join_commands]
  triggers   = { ip = var.control_plane.ips[count.index + 1] }

  provisioner "file" {
    connection {
      type        = "ssh"
      host        = local.cp_ips[count.index + 1]
      user        = local.ssh_user
      private_key = file(pathexpand("~/.ssh/id_ed25519"))
      host_key    = ""
      timeout     = "5m"
    }
    source      = "/tmp/kubeadm-join-cp.sh"
    destination = "/tmp/kubeadm-join-cp.sh"
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      host        = local.cp_ips[count.index + 1]
      user        = local.ssh_user
      private_key = file(pathexpand("~/.ssh/id_ed25519"))
      host_key    = ""
      timeout     = "15m"
    }
    inline = [
      # kube-vip static pod on secondary CPs
      "IFACE=$(ip route | grep default | awk '{print $5}' | head -1)",
      "sudo mkdir -p /etc/kubernetes/manifests",
      "sudo ctr image pull ghcr.io/kube-vip/kube-vip:${var.kube_vip_version}",
      "sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${var.kube_vip_version} vip /kube-vip manifest pod --interface $IFACE --address ${var.control_plane.vip} --controlplane --arp --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml",

      # Join as control plane
      "sudo bash /tmp/kubeadm-join-cp.sh --apiserver-advertise-address=${local.cp_ips[count.index + 1]} --node-name=k8s-cp-${count.index + 2} 2>&1 | sudo tee /var/log/kubeadm-join.log",

      # kubeconfig
      "mkdir -p /home/${local.ssh_user}/.kube",
      "sudo cp /etc/kubernetes/admin.conf /home/${local.ssh_user}/.kube/config",
      "sudo chown ${local.ssh_user}:${local.ssh_user} /home/${local.ssh_user}/.kube/config",
    ]
  }
}

# Step 5: Join workers
resource "null_resource" "join_workers" {
  count = var.worker_count
  depends_on = [
    null_resource.fetch_join_commands,
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

output "control_plane_vip" { value = var.control_plane.vip }
output "control_plane_ips" { value = local.cp_ips }
output "worker_ips" {
  value = [for ip in var.worker_ips : split("/", ip)[0]]
}
