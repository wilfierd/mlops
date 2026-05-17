# Cluster-side prerequisites for the RayService:
# - app namespace where RayService lives
# - kuberay-operator (Helm) that watches RayService CRs and reconciles pods
#
# RayService manifest itself + reliability primitives are in sibling files
# (locals.tf, rayservice.tf, pdb.tf). Terraform loads every *.tf in this
# directory automatically so the split is purely organizational.

resource "kubernetes_namespace" "app" {
  metadata {
    name = var.namespace
  }
}

resource "helm_release" "kuberay_operator" {
  name             = "kuberay-operator"
  repository       = "https://ray-project.github.io/kuberay-helm/"
  chart            = "kuberay-operator"
  version          = var.operator_chart_version
  namespace        = var.operator_namespace
  create_namespace = true

  set {
    name  = "image.pullPolicy"
    value = "IfNotPresent"
  }
}
