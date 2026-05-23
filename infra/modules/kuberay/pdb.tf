# PodDisruptionBudget protects the singleton Ray head against voluntary
# disruptions (node drain, MNG rolling upgrade, kubectl drain). It does NOT
# protect against involuntary failures (node crash, OOM kill).

# Head is the singleton (Serve HTTP proxy + GCS + autoscaler). Losing it
# restarts the whole RayService, so block all voluntary eviction.
resource "kubectl_manifest" "pdb_head" {
  yaml_body = yamlencode({
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = "${var.service_name}-head"
      namespace = var.namespace
    }
    spec = {
      maxUnavailable = 0
      selector = {
        matchLabels = {
          "ray.io/cluster"   = var.service_name
          "ray.io/node-type" = "head"
        }
      }
    }
  })

  depends_on = [kubectl_manifest.rayservice]
}
