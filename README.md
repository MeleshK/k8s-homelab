# k8s-homelab

Terraform/OpenTofu configuration for provisioning a highly available Kubernetes cluster on Proxmox. Creates 3 control plane nodes behind a kube-vip virtual IP, plus configurable worker nodes — all automated from VM creation through cluster bootstrap.

## Requirements

- Proxmox VE node with a VM template (Rocky 9 or Ubuntu 22.04 cloud image)
- OpenTofu or Terraform
- SSH key pair at `~/.ssh/id_ed25519`
- Proxmox `snippets` storage enabled on the `local` datastore

### Creating the VM template

SSH into your Proxmox host and run:

```bash
# Rocky 9 (default)
wget https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2
qm create 9000 --name "rocky9-template" --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 Rocky-9-GenericCloud.latest.x86_64.qcow2 local-lvm
qm set 9000 --scsihw virtio-scsi-single --scsi0 local-lvm:vm-9000-disk-0,discard=on,iothread=1
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1
qm template 9000
```

```bash
# Ubuntu 22.04 (if using os_type = "ubuntu")
wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
qm create 9000 --name "ubuntu-jammy-template" --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 jammy-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsihw virtio-scsi-single --scsi0 local-lvm:vm-9000-disk-0,discard=on,iothread=1
qm set 9000 --ide2 local-lvm:cloudinit
qm set 9000 --boot c --bootdisk scsi0
qm set 9000 --serial0 socket --vga serial0
qm set 9000 --agent enabled=1
qm template 9000
```

## Usage

```bash
cp terraforms.tfvars.example terraform.tfvars
# edit terraform.tfvars with your values

tofu init
tofu apply
```

After apply completes, copy the kubeconfig from the primary control plane:

```bash
scp -i ~/.ssh/id_ed25519 rocky@10.0.0.40:/home/rocky/.kube/config ~/.kube/config
# replace rocky/10.0.0.40 if using ubuntu or different IPs
kubectl get nodes
```

## Configuration

Copy `terraforms.tfvars.example` to `terraform.tfvars` and set the required values.

### Required

| Variable | Description |
|---|---|
| `proxmox_api_url` | Proxmox API endpoint e.g. `https://10.0.0.11:8006/` |
| `proxmox_user` | Proxmox user e.g. `root@pam` |
| `proxmox_password` | Proxmox password |
| `ssh_public_key` | Public key injected into VMs — must match `~/.ssh/id_ed25519` |
| `vm_password` | Console login password for the VM user (rocky/ubuntu) |

### Optional

| Variable | Default | Description |
|---|---|---|
| `proxmox_node` | `"pve"` | Proxmox node name |
| `template_id` | `9000` | VM template ID to clone from |
| `os_type` | `"rocky"` | `"rocky"` or `"ubuntu"` |
| `k8s_version` | `"1.34"` | Kubernetes version |
| `pod_cidr` | `"192.168.0.0/16"` | Pod network CIDR (Calico) |
| `worker_count` | `2` | Number of worker nodes |
| `kube_vip_version` | `"v0.8.9"` | kube-vip image tag |

### Control plane

```hcl
control_plane = {
  cores  = 2
  memory = 4096
  disk   = 30
  ips    = ["10.0.0.40/24", "10.0.0.41/24", "10.0.0.42/24"]
  vip    = "10.0.0.39"   # virtual IP — must not be assigned to any host
  gw     = "10.0.0.1"
}
```

### Workers

```hcl
worker = {
  cores  = 2
  memory = 8192
  disk   = 30
}

worker_ips = ["10.0.0.43/24", "10.0.0.44/24", "10.0.0.45/24"]
```

`worker_ips` must have at least `worker_count` entries.

## IP layout

| Address | Role |
|---|---|
| `10.0.0.39` | kube-vip VIP — kubectl endpoint |
| `10.0.0.40` | k8s-cp-1 (primary) |
| `10.0.0.41` | k8s-cp-2 |
| `10.0.0.42` | k8s-cp-3 |
| `10.0.0.43` | k8s-worker-1 |
| `10.0.0.44` | k8s-worker-2 |
| `10.0.0.45` | k8s-worker-3 |

## How it works

Cloud-init handles OS prerequisites (containerd, kubeadm, kubelet). Terraform remote-exec handles cluster bootstrapping in sequence:

```
VMs created (all in parallel)
    ↓
cloud-init status --wait (all 3 CPs in parallel)
    ↓
k8s-cp-1: kube-vip static pod → kubeadm init → Calico → save join tokens
    ↓
fetch join tokens to local machine (with retry)
    ↓
k8s-cp-2, k8s-cp-3: kube-vip static pod → kubeadm join --control-plane  (parallel)
workers: cloud-init wait → copy join script → kubeadm join               (parallel)
```

kube-vip runs as a static pod on each control plane and provides ARP-based leader election for the VIP. The apiserver endpoint is always `VIP:6443`, so kubectl and workers continue working if any single CP node goes down.

## Outputs

```
control_plane_vip   = "10.0.0.39"
control_plane_ips   = ["10.0.0.40", "10.0.0.41", "10.0.0.42"]
worker_ips          = ["10.0.0.43", "10.0.0.44", "10.0.0.45"]
```

## VM IDs

| VM | ID |
|---|---|
| k8s-cp-1 | 200 |
| k8s-cp-2 | 201 |
| k8s-cp-3 | 202 |
| k8s-worker-1 | 210 |
| k8s-worker-2 | 211 |
| k8s-worker-3 | 212 |
