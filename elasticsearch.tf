provider "kubectl" {
  host                   = scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].host
  token                  = scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].token
  cluster_ca_certificate = base64decode(scaleway_k8s_cluster.kapsule_multi_az.kubeconfig[0].cluster_ca_certificate)
  load_config_file       = false
}

resource "helm_release" "eck" {
  name      = "elastic-operator"
  namespace = "elastic-system"

  create_namespace = true

  repository = "https://helm.elastic.co"
  chart      = "eck-operator"

  depends_on = [helm_release.nginx_ingress]
}

resource "kubernetes_namespace" "elasticsearch" {
  metadata {
    name = "elasticsearch"
  }

  depends_on = [helm_release.eck]
}

resource "kubectl_manifest" "elasticsearch" {
  yaml_body = <<YAML
apiVersion: "elasticsearch.k8s.elastic.co/v1"
kind: "Elasticsearch"
metadata:
  name: "multi-az"
  namespace: "${kubernetes_namespace.elasticsearch.metadata[0].name}"
  annotations:
    "eck.k8s.elastic.co/downward-node-labels": "topology.kubernetes.io/zone"
spec:
  version: "8.10.2"
  nodeSets:
  - name: "default"
    count: 3
    volumeClaimTemplates:
    - metadata:
        name: "elasticsearch-data"
      spec:
        accessModes:
        - "ReadWriteOnce"
        resources:
          requests:
            storage: "1Gi"
        storageClassName: "scw-bssd"
    config:
      node.attr.zone: "$${ZONE}"
      cluster.routing.allocation.awareness.attributes: "k8s_node_name,zone"
      node.store.allow_mmap: false
    podTemplate:
      spec:
        containers:
        - name: "elasticsearch"
          env:
          - name: "ZONE"
            valueFrom:
              fieldRef:
                fieldPath: "metadata.annotations['topology.kubernetes.io/zone']"
        topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: "topology.kubernetes.io/zone"
          whenUnsatisfiable: "DoNotSchedule"
          labelSelector:
            matchLabels:
              "elasticsearch.k8s.elastic.co/cluster-name": "multi-az"
              "elasticsearch.k8s.elastic.co/statefulset-name": "multi-az-es-default"
YAML
}

resource "kubectl_manifest" "kibana" {
  yaml_body = <<YAML
apiVersion: "kibana.k8s.elastic.co/v1"
kind: "Kibana"
metadata:
  name: "kibana"
  namespace: "${kubernetes_namespace.elasticsearch.metadata[0].name}"
spec:
  version: "8.10.2"
  count: 3
  elasticsearchRef:
    name: "multi-az"
  http:
    tls:
      selfSignedCertificate:
        disabled: true
YAML
}

resource "kubernetes_ingress_v1" "kibana" {
  metadata {
    name      = "kibana"
    namespace = kubernetes_namespace.elasticsearch.metadata[0].name
  }

  spec {
    ingress_class_name = "nginx"
    rule {
      host = "kibana.scw.your-domain.tld"
      http {
        path {
          backend {
            service {
              name = "kibana-kb-http"
              port {
                number = 5601
              }
            }
          }
        }
      }
    }
  }
}

resource "scaleway_domain_record" "kibana" {
  dns_zone        = data.scaleway_domain_zone.multi-az.id
  name            = "kibana"
  type            = "CNAME"
  data            = "ingress.scw.your-domain.tld."
  ttl             = 300
  keep_empty_zone = true
}
