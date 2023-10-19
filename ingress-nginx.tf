resource "time_sleep" "wait_30_seconds" {
  depends_on = [scaleway_k8s_pool.pool-multi-az]

  create_duration = "60s"
}

provider "kubernetes" {
  host                   = scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].host
  token                  = scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].token
  cluster_ca_certificate = base64decode(scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].host
    token                  = scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].token
    cluster_ca_certificate = base64decode(scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].cluster_ca_certificate)
  }
}

resource "helm_release" "nginx_ingress" {
  name      = "ingress-nginx"
  namespace = "ingress-nginx"

  create_namespace = true

  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"

  values = [
    <<-EOF
      controller:
        replicaCount: 3

        topologySpreadConstraints:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
              app.kubernetes.io/instance: ingress-nginx
              app.kubernetes.io/component: controller
          topologyKey: topology.kubernetes.io/zone
          maxSkew: 1
          whenUnsatisfiable: DoNotSchedule

        service:
          enabled: false
        config:
          location-snippet: |
            location /up {
              return 200 'up';
            }
    EOF
  ]

  depends_on = [time_sleep.wait_30_seconds]
}

resource "kubernetes_service" "ingress-nginx" {
  for_each = {
    "fr-par-1" = 1,
    "fr-par-2" = 2
  }

  metadata {
    name      = "ingress-nginx-controller-${each.key}"
    namespace = helm_release.nginx_ingress.namespace

    annotations = {
      "service.beta.kubernetes.io/scw-loadbalancer-zone" : each.key
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name"      = "ingress-nginx"
      "app.kubernetes.io/instance"  = "ingress-nginx"
      "app.kubernetes.io/component" = "controller"
    }

    port {
      app_protocol = "http"
      name         = "http"
      port         = 80
      protocol     = "TCP"
      target_port  = "http"
    }

    port {
      app_protocol = "https"
      name         = "https"
      port         = 443
      protocol     = "TCP"
      target_port  = "https"
    }

    type = "LoadBalancer"
  }

  lifecycle {
    ignore_changes = [
      metadata[0].annotations["service.beta.kubernetes.io/scw-loadbalancer-id"],
      metadata[0].labels["k8s.scaleway.com/cluster"],
      metadata[0].labels["k8s.scaleway.com/kapsule"],
      metadata[0].labels["k8s.scaleway.com/managed-by-scaleway-cloud-controller-manager"],
    ]
  }
}

data "scaleway_domain_zone" "multi-az" {
  domain    = "your-domain.tld"
  subdomain = "scw"
}

resource "scaleway_domain_record" "multi-az" {
  dns_zone        = data.scaleway_domain_zone.multi-az.id
  name            = "ingress"
  type            = "A"
  data            = kubernetes_service.ingress-nginx["fr-par-1"].status.0.load_balancer.0.ingress.0.ip
  ttl             = 60
  keep_empty_zone = true

  http_service {
    ips = [
      kubernetes_service.ingress-nginx["fr-par-1"].status.0.load_balancer.0.ingress.0.ip,
      kubernetes_service.ingress-nginx["fr-par-2"].status.0.load_balancer.0.ingress.0.ip,
    ]
    must_contain = "up"
    url          = "http://ingress.scw.your-domain.tld/up"
    user_agent   = "scw_dns_healtcheck"
    strategy     = "all"
  }
}
