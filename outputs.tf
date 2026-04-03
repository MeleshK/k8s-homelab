# Step 1: Wait for all control plane cloud-inits
resource "null_resource" "wait_control_planes" {
  count      = local.cp_count
  depends_on = [proxmox_virtual_environment_vm.control_plane]
  triggers   = { vm_id = proxmox_virtual_environment_vm.control_plane[count.index].id }

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
    inline = compact([
      # Phase 1: kube-vip WITHOUT --leaderElection (HA only) — claims VIP before apiserver exists
      var.ha_enabled ? "sudo mkdir -p /etc/kubernetes/manifests" : "",
      var.ha_enabled ? "IFACE=$(ip route | grep default | awk '{print $5}' | head -1)" : "",
      var.ha_enabled ? "sudo ctr image pull ghcr.io/kube-vip/kube-vip:${var.kube_vip_version}" : "",
      var.ha_enabled ? "sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${var.kube_vip_version} vip-bootstrap /kube-vip manifest pod --interface $IFACE --address ${var.control_plane.vip} --controlplane --arp | sudo tee /etc/kubernetes/manifests/kube-vip.yaml" : "",

      # Wait for kube-vip to claim VIP (HA only)
      var.ha_enabled ? "echo 'Waiting for kube-vip to claim ${var.control_plane.vip}...' && for i in $(seq 1 30); do ping -c1 -W1 ${var.control_plane.vip} > /dev/null 2>&1 && echo 'VIP is up' && break || echo \"Attempt $i: not up yet, waiting 5s...\"; sleep 5; done" : "",

      # kubeadm init — HA adds VIP endpoint + cert upload; pipefail catches errors through tee
      var.ha_enabled ?
        "set -o pipefail && sudo kubeadm init --control-plane-endpoint=${var.control_plane.vip}:6443 --pod-network-cidr=${var.pod_cidr} --apiserver-advertise-address=${local.cp_ips[0]} --upload-certs --node-name=k8s-cp-1 2>&1 | sudo tee /var/log/kubeadm-init.log" :
        "set -o pipefail && sudo kubeadm init --pod-network-cidr=${var.pod_cidr} --apiserver-advertise-address=${local.cp_ips[0]} --node-name=k8s-cp-1 2>&1 | sudo tee /var/log/kubeadm-init.log",

      # kubeconfig (always)
      "mkdir -p /home/${local.ssh_user}/.kube",
      "sudo cp /etc/kubernetes/admin.conf /home/${local.ssh_user}/.kube/config",
      "sudo chown ${local.ssh_user}:${local.ssh_user} /home/${local.ssh_user}/.kube/config",

      # kube-vip local kubeconfig (HA only) — breaks VIP bootstrap deadlock.
      # admin.conf server = https://VIP:6443, but phase 2 kube-vip doesn't hold the VIP
      # yet, so it can't reach the API to win leader election. localhost:6443 is always
      # reachable on the primary CP; API server cert includes localhost as a SAN.
      var.ha_enabled ? "sudo cp /etc/kubernetes/admin.conf /etc/kubernetes/kube-vip.conf" : "",
      var.ha_enabled ? "sudo sed -i 's|https://${var.control_plane.vip}:6443|https://localhost:6443|g' /etc/kubernetes/kube-vip.conf" : "",

      # kube-vip RBAC (HA only) — kubernetes-admin needs lease access for leader election
      var.ha_enabled ? "kubectl --kubeconfig=/home/${local.ssh_user}/.kube/config apply -f - <<'RBAC'\napiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRole\nmetadata:\n  name: system:kube-vip-role\nrules:\n- apiGroups: [\"coordination.k8s.io\"]\n  resources: [\"leases\"]\n  verbs: [\"get\",\"create\",\"update\",\"list\",\"watch\"]\n---\napiVersion: rbac.authorization.k8s.io/v1\nkind: ClusterRoleBinding\nmetadata:\n  name: system:kube-vip-binding\nroleRef:\n  apiGroup: rbac.authorization.k8s.io\n  kind: ClusterRole\n  name: system:kube-vip-role\nsubjects:\n- kind: User\n  name: kubernetes-admin\n  apiGroup: rbac.authorization.k8s.io\nRBAC" : "",

      # Phase 2: replace kube-vip manifest with --leaderElection (HA only)
      var.ha_enabled ? "sudo ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${var.kube_vip_version} vip-ha /kube-vip manifest pod --interface $IFACE --address ${var.control_plane.vip} --controlplane --arp --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml" : "",
      var.ha_enabled ? "sudo sed -i 's|/etc/kubernetes/admin.conf|/etc/kubernetes/kube-vip.conf|g' /etc/kubernetes/manifests/kube-vip.yaml" : "",

      # Wait for apiserver healthy via VIP (HA only — non-HA apiserver is already up after init)
      var.ha_enabled ? "echo 'Waiting for apiserver at ${var.control_plane.vip}:6443...' && for i in $(seq 1 40); do curl -sk https://${var.control_plane.vip}:6443/healthz | grep -q ok && echo 'apiserver ready' && break || echo \"Attempt $i: not ready, waiting 5s...\"; sleep 5; done" : "",

      # Calico (always)
      "kubectl --kubeconfig=/home/${local.ssh_user}/.kube/config create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml",
      "kubectl --kubeconfig=/home/${local.ssh_user}/.kube/config apply -f /tmp/calico-installation.yaml",

      # Worker join command (always)
      "sudo kubeadm token create --print-join-command | sudo tee /tmp/kubeadm-join-worker.sh",

      # CP join command (HA only) — re-upload certs to avoid 2h expiry during slow applies
      var.ha_enabled ? "CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1) && JOIN=$(sudo kubeadm token create --print-join-command) && echo \"$JOIN --control-plane --certificate-key $CERT_KEY\" | sudo tee /tmp/kubeadm-join-cp.sh" : "",
    ])
  }
}

# Step 3: Fetch both join commands to local machine (with retry)
resource "null_resource" "fetch_join_commands" {
  depends_on = [null_resource.init_primary_cp]
  triggers   = { vm_id = proxmox_virtual_environment_vm.control_plane[0].id }

  provisioner "local-exec" {
    command = <<-EOF
      for i in $(seq 1 12); do
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
          -i ~/.ssh/id_ed25519 \
          ${local.ssh_user}@${local.cp_ips[0]} \
          'cat /tmp/kubeadm-join-worker.sh' > /tmp/kubeadm-join-worker.sh \
          && [ -s /tmp/kubeadm-join-worker.sh ] \
          && { [ "${var.ha_enabled}" != "true" ] || {
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
              -i ~/.ssh/id_ed25519 \
              ${local.ssh_user}@${local.cp_ips[0]} \
              'cat /tmp/kubeadm-join-cp.sh' > /tmp/kubeadm-join-cp.sh \
            && [ -s /tmp/kubeadm-join-cp.sh ]; }; } \
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
  count      = var.ha_enabled ? local.cp_count - 1 : 0
  depends_on = [null_resource.fetch_join_commands]
  triggers   = { vm_id = proxmox_virtual_environment_vm.control_plane[count.index + 1].id }

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

output "control_plane_vip" { value = var.control_plane.vip }
output "control_plane_ips" { value = local.cp_ips }
output "worker_ips" {
  value = [for ip in var.worker_ips : split("/", ip)[0]]
}
