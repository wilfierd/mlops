# Apply the RayService CR. We use kubectl_manifest (gavinbunney/kubectl)
# instead of kubernetes_manifest because the latter does a server-side
# dry-run at plan time — which fails on a fresh apply against an EKS cluster
# that doesn't exist yet. kubectl_manifest defers everything to apply time.

resource "kubectl_manifest" "rayservice" {
  yaml_body = yamlencode(local.rayservice)

  server_side_apply = true
  wait              = false

  depends_on = [
    helm_release.kuberay_operator,
    kubernetes_namespace.app,
  ]
}
