terraform {
  required_version = ">= 1.7.0, < 2.0.0"

  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "1.279.0"
    }
  }
}

provider "alicloud" {
  region = var.region
}

variable "region" {
  description = "Alibaba Cloud region for the disposable demo."
  type        = string
}

variable "name_prefix" {
  description = "Stable name used for the ACK cluster and its resources."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the demo VPC."
  type        = string
}

variable "vsw_cidr" {
  description = "CIDR for the worker vSwitch."
  type        = string
}

variable "pod_cidr" {
  description = "Cluster-wide pod CIDR used by Cilium Kubernetes IPAM."
  type        = string
}

variable "service_cidr" {
  description = "Kubernetes Service CIDR."
  type        = string
}

variable "node_cidr_mask" {
  description = "Per-node PodCIDR mask."
  type        = number
}

variable "cluster_spec" {
  description = "ACK managed Pro cluster specification."
  type        = string
}

variable "enable_nat_gateway" {
  description = "Whether ACK creates a NAT gateway for outbound access."
  type        = bool
}

variable "enable_public_apiserver" {
  description = "Whether ACK creates an Internet-facing API server endpoint."
  type        = bool
}

variable "node_pool_desired_size" {
  description = "Number of worker nodes in the fixed-size demo node pool."
  type        = number
}

variable "instance_type" {
  description = "ECS instance type for ACK workers."
  type        = string
}

variable "system_disk_category" {
  description = "ECS system disk category for ACK workers."
  type        = string
}

variable "system_disk_size" {
  description = "ECS system disk size in GiB."
  type        = number
}

variable "node_password" {
  description = "Password for the disposable ACK worker nodes."
  type        = string
  sensitive   = true
}

variable "zone_id" {
  description = "Optional zone override. An empty value selects a compatible zone."
  type        = string
  default     = ""
}

data "alicloud_zones" "compatible" {
  count                       = var.zone_id == "" ? 1 : 0
  available_resource_creation = "VSwitch"
  available_instance_type     = var.instance_type
}

locals {
  zone_id = var.zone_id != "" ? var.zone_id : data.alicloud_zones.compatible[0].zones[0].id

  bpf_lsm_user_data = <<-USERDATA
    #!/usr/bin/env bash
    set -euo pipefail

    log() {
      logger -t ack-byocni-bpf-lsm -- "$*"
      printf '[ack-byocni-bpf-lsm] %s\n' "$*"
    }

    lsm_file="/sys/kernel/security/lsm"
    marker="/var/lib/ack-byocni-bpf-lsm-configured"

    if [[ -r "$lsm_file" ]] && tr ',' '\n' < "$lsm_file" | grep -Fxq bpf; then
      log "BPF LSM is already active; no kernel change or reboot is required"
      exit 0
    fi

    if [[ -f "$marker" ]]; then
      log "BPF LSM kernel arguments were already configured; refusing another reboot loop"
      exit 0
    fi

    command -v grubby >/dev/null 2>&1 || {
      log "grubby is unavailable; cannot enable BPF LSM"
      exit 1
    }

    current_lsms="$(tr -d '[:space:]' < "$lsm_file" 2>/dev/null || true)"
    if [[ -z "$current_lsms" ]]; then
      current_lsms="lockdown,capability,landlock,yama,integrity,selinux"
    fi

    case ",$current_lsms," in
      *,bpf,*) desired_lsms="$current_lsms" ;;
      *)       desired_lsms="$current_lsms,bpf" ;;
    esac

    log "configuring kernel argument lsm=$desired_lsms"
    grubby --update-kernel=ALL --args="lsm=$desired_lsms"
    install -d -m 0755 "$(dirname "$marker")"
    touch "$marker"

    log "scheduling a one-time reboot in two minutes to activate BPF LSM"
    systemd-run \
      --unit=ack-byocni-bpf-lsm-reboot \
      --on-active=2m \
      /usr/bin/systemctl reboot
  USERDATA
}

resource "alicloud_vpc" "demo" {
  vpc_name   = "${var.name_prefix}-vpc"
  cidr_block = var.vpc_cidr

  tags = {
    Project   = "ack-byocni"
    Lifecycle = "terraform"
  }
}

resource "alicloud_vswitch" "workers" {
  vswitch_name = "${var.name_prefix}-workers"
  vpc_id       = alicloud_vpc.demo.id
  cidr_block   = var.vsw_cidr
  zone_id      = local.zone_id

  tags = {
    Project   = "ack-byocni"
    Lifecycle = "terraform"
  }
}

resource "alicloud_cs_managed_kubernetes" "demo" {
  name                           = var.name_prefix
  cluster_spec                   = var.cluster_spec
  vswitch_ids                    = [alicloud_vswitch.workers.id]
  new_nat_gateway                = var.enable_nat_gateway
  pod_cidr                       = var.pod_cidr
  service_cidr                   = var.service_cidr
  node_cidr_mask                 = var.node_cidr_mask
  proxy_mode                     = "ipvs"
  slb_internet_enabled           = var.enable_public_apiserver
  deletion_protection            = false
  timezone                       = "Asia/Shanghai"
  skip_set_certificate_authority = true

  addons {
    name     = "kube-flannel-ds"
    disabled = true
  }

  addons {
    name = "cloud-controller-manager"
    config = jsonencode({
      EnableCloudRoutes = "true"
      BackendType       = "NodePort"
    })
  }

  tags = {
    Project   = "ack-byocni"
    Lifecycle = "terraform"
  }

  timeouts {
    create = "90m"
    update = "60m"
    delete = "60m"
  }
}

resource "alicloud_cs_kubernetes_node_pool" "workers" {
  cluster_id            = alicloud_cs_managed_kubernetes.demo.id
  node_pool_name        = "${var.name_prefix}-workers"
  vswitch_ids           = [alicloud_vswitch.workers.id]
  instance_types        = [var.instance_type]
  instance_charge_type  = "PostPaid"
  desired_size          = var.node_pool_desired_size
  system_disk_category  = var.system_disk_category
  system_disk_size      = var.system_disk_size
  image_type            = "AliyunLinux3ContainerOptimized"
  runtime_name          = "containerd"
  install_cloud_monitor = false
  password              = var.node_password
  user_data             = base64encode(local.bpf_lsm_user_data)

  tags = {
    Project   = "ack-byocni"
    Lifecycle = "terraform"
  }

  depends_on = [alicloud_cs_managed_kubernetes.demo]
}

data "alicloud_cs_cluster_credential" "demo" {
  cluster_id  = alicloud_cs_managed_kubernetes.demo.id
  output_file = "${path.module}/kubeconfig"

  depends_on = [alicloud_cs_kubernetes_node_pool.workers]
}

output "cluster_id" {
  description = "ACK cluster ID."
  value       = alicloud_cs_managed_kubernetes.demo.id
}

output "cluster_name" {
  description = "ACK cluster name."
  value       = alicloud_cs_managed_kubernetes.demo.name
}

output "kubernetes_version" {
  description = "ACK Kubernetes version selected at creation time."
  value       = alicloud_cs_managed_kubernetes.demo.version
}

output "selected_zone_id" {
  description = "Zone used by the worker vSwitch and node pool."
  value       = local.zone_id
}

output "vpc_id" {
  description = "Terraform-owned demo VPC ID."
  value       = alicloud_vpc.demo.id
}
