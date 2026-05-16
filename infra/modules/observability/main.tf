resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.namespace
  }
}

resource "random_password" "grafana" {
  count   = var.grafana_admin_password == "" ? 1 : 0
  length  = 16
  special = true
}

locals {
  grafana_password = var.grafana_admin_password != "" ? var.grafana_admin_password : random_password.grafana[0].result
}

# kube-prometheus-stack bundles Prometheus + Alertmanager + Grafana +
# kube-state-metrics + node-exporter + CRDs (ServiceMonitor, PrometheusRule).
# This is the standard "give me a working obs stack in one helm install" path.
resource "helm_release" "kube_prom_stack" {
  name       = "kube-prom-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_version
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        retention = var.prometheus_retention
        resources = {
          requests = { memory = var.prometheus_memory }
        }
        # Discover ServiceMonitors from ANY namespace, not just monitoring's.
        # Required so the Ray ServiceMonitor in `llm-chat` ns is picked up.
        serviceMonitorSelectorNilUsesHelmValues = false
        serviceMonitorNamespaceSelector         = {}
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
      }
    }
    grafana = {
      adminPassword = local.grafana_password
      persistence = {
        enabled = var.persist_grafana
      }
      # Sidecar auto-imports ConfigMaps with label grafana_dashboard=1 as dashboards.
      sidecar = {
        dashboards = {
          enabled         = true
          label           = "grafana_dashboard"
          searchNamespace = "ALL"
        }
      }
      service = {
        type = "ClusterIP"
      }
    }
    alertmanager = {
      enabled = false # turn off in lab to save resources
    }
  })]

  depends_on = [kubernetes_namespace.monitoring]
}

# Tell Prometheus to scrape Ray head pod's metrics endpoint (port 8080, /metrics).
# KubeRay tags Ray pods with `ray.io/cluster=<name>` and `ray.io/node-type=head`.
resource "kubectl_manifest" "ray_service_monitor" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "ray-head-metrics"
      namespace = kubernetes_namespace.monitoring.metadata[0].name
      labels = {
        release = "kube-prom-stack"
      }
    }
    spec = {
      namespaceSelector = { matchNames = [var.ray_namespace] }
      selector = {
        matchExpressions = [{
          key      = "ray.io/cluster"
          operator = "Exists"
        }]
      }
      endpoints = [{
        port     = "metrics"
        path     = "/metrics"
        interval = "15s"
      }]
    }
  })

  depends_on = [helm_release.kube_prom_stack]
}

# Provision a default Ray Serve dashboard as a ConfigMap. The Grafana sidecar
# auto-imports any ConfigMap with label grafana_dashboard=1.
resource "kubernetes_config_map" "ray_dashboard" {
  metadata {
    name      = "ray-serve-dashboard"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "ray-serve.json" = file("${path.module}/dashboards/ray-serve.json")
  }

  depends_on = [helm_release.kube_prom_stack]
}
