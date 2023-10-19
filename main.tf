terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = ">= 2.28.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">=2.23.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "2.11.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.4.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.14.0"
    }
  }
  required_version = ">= 1.0.0"
}

provider "scaleway" {
  region = "fr-par"
}

resource "scaleway_vpc" "vpc_multi_az" {
  name = "vpc-multi-az"
  tags = ["multi-az"]
}

resource "scaleway_vpc_private_network" "pn_multi_az" {
  name   = "pn-multi-az"
  vpc_id = scaleway_vpc.vpc_multi_az.id
  tags   = ["multi-az"]
}

resource "scaleway_k8s_cluster" "kapsule_multi_az" {
  name = "kapsule-multi-az"
  tags = ["multi-az"]

  type    = "kapsule"
  version = "1.28"
  cni     = "cilium"

  delete_additional_resources = true

  autoscaler_config {
    ignore_daemonsets_utilization = true
    balance_similar_node_groups   = true
  }

  auto_upgrade {
    enable                        = true
    maintenance_window_day        = "sunday"
    maintenance_window_start_hour = 2
  }

  private_network_id = scaleway_vpc_private_network.pn_multi_az.id
}

resource "scaleway_k8s_pool" "pool-multi-az" {
  for_each = {
    "fr-par-1" = 1,
    "fr-par-2" = 2,
    "fr-par-3" = 3
  }

  name                   = "pool-${each.key}"
  zone                   = each.key
  tags                   = ["multi-az"]
  cluster_id             = scaleway_k8s_cluster.kapsule_multi_az.id
  node_type              = "PRO2-XXS"
  size                   = 2
  min_size               = 2
  max_size               = 3
  autoscaling            = true
  autohealing            = true
  container_runtime      = "containerd"
  root_volume_size_in_gb = 20
}

data "template_file" "kubeconfig" {
  template = <<EOT
apiVersion: v1
clusters:
- name: "$${cluster_name}"
  cluster:
    certificate-authority-data: $${ca_cert}
    server: "$${host}"
contexts:
- name: admin@kapsule-multi-az
  context:
    cluster: "kapsule-multi-az"
    user: kapsule-multi-az-admin
current-context: admin@kapsule-multi-az
kind: Config
preferences: {}
users:
- name: kapsule-multi-az-admin
  user:
    token: $${token}
EOT

  vars = {
    cluster_name = scaleway_k8s_cluster.kapsule_multi_az.name
    host         = scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].host
    token        = scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].token
    ca_cert      = scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].cluster_ca_certificate
  }
}

resource "local_file" "kubeconfig" {
  content  = data.template_file.kubeconfig.rendered
  filename = "./kubeconfig"
}
