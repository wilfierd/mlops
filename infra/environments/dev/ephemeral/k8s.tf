###############################################################################
# App namespace.
###############################################################################
resource "kubernetes_namespace" "app" {
  metadata {
    name = var.kubernetes_namespace
    labels = {
      "app.kubernetes.io/part-of" = local.name_prefix
    }
  }

  depends_on = [module.eks]
}

###############################################################################
# StorageClass — Retain reclaim, so PV deletion in this stack does NOT delete
# the underlying EBS volume (which is owned by the persistent stack).
###############################################################################
resource "kubectl_manifest" "sc_gp3_retain" {
  yaml_body = yamlencode({
    apiVersion = "storage.k8s.io/v1"
    kind       = "StorageClass"
    metadata = {
      name = "gp3-retain"
    }
    provisioner       = "ebs.csi.aws.com"
    reclaimPolicy     = "Retain"
    volumeBindingMode = "WaitForFirstConsumer"
    parameters = {
      type      = "gp3"
      encrypted = "true"
    }
  })

  depends_on = [module.eks]
}

###############################################################################
# PV qdrant-data-pv — binds to the persistent EBS volume holding Qdrant data.
###############################################################################
resource "kubectl_manifest" "qdrant_pv" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolume"
    metadata = {
      name = "qdrant-data-pv"
      labels = {
        "app.kubernetes.io/name" = "qdrant"
      }
    }
    spec = {
      capacity = {
        storage = "${local.qdrant_volume_size}Gi"
      }
      accessModes                   = ["ReadWriteOnce"]
      persistentVolumeReclaimPolicy = "Retain"
      storageClassName              = "gp3-retain"
      csi = {
        driver       = "ebs.csi.aws.com"
        volumeHandle = local.qdrant_volume_id
        fsType       = "ext4"
      }
      # Pin to worker AZ so scheduler places the pod on a node that can attach.
      nodeAffinity = {
        required = {
          nodeSelectorTerms = [{
            matchExpressions = [{
              key      = "topology.ebs.csi.aws.com/zone"
              operator = "In"
              values   = [local.worker_az]
            }]
          }]
        }
      }
      claimRef = {
        namespace = var.kubernetes_namespace
        name      = "qdrant-data-pvc"
      }
    }
  })

  depends_on = [kubectl_manifest.sc_gp3_retain]
}

###############################################################################
# PVC qdrant-data-pvc — consumed by the Qdrant StatefulSet (deployed by app
# manifests in P3, not here).
###############################################################################
resource "kubectl_manifest" "qdrant_pvc" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolumeClaim"
    metadata = {
      name      = "qdrant-data-pvc"
      namespace = var.kubernetes_namespace
    }
    spec = {
      accessModes = ["ReadWriteOnce"]
      resources = {
        requests = {
          storage = "${local.qdrant_volume_size}Gi"
        }
      }
      storageClassName = "gp3-retain"
      volumeName       = "qdrant-data-pv"
    }
  })

  depends_on = [
    kubectl_manifest.qdrant_pv,
    kubernetes_namespace.app,
  ]
}

###############################################################################
# PV llm-cache-pv — binds to the persistent EBS volume holding HF model cache
# for vllm-openai. Avoids re-downloading 5GB AWQ on every cluster-up.
###############################################################################
resource "kubectl_manifest" "llm_cache_pv" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolume"
    metadata = {
      name = "llm-cache-pv"
      labels = {
        "app.kubernetes.io/name" = "vllm-server"
      }
    }
    spec = {
      capacity = {
        storage = "${local.llm_cache_size}Gi"
      }
      accessModes                   = ["ReadWriteOnce"]
      persistentVolumeReclaimPolicy = "Retain"
      storageClassName              = "gp3-retain"
      csi = {
        driver       = "ebs.csi.aws.com"
        volumeHandle = local.llm_cache_volume_id
        fsType       = "ext4"
      }
      nodeAffinity = {
        required = {
          nodeSelectorTerms = [{
            matchExpressions = [{
              key      = "topology.ebs.csi.aws.com/zone"
              operator = "In"
              values   = [local.worker_az]
            }]
          }]
        }
      }
      claimRef = {
        namespace = var.kubernetes_namespace
        name      = "llm-cache-pvc"
      }
    }
  })

  depends_on = [kubectl_manifest.sc_gp3_retain]
}

resource "kubectl_manifest" "llm_cache_pvc" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolumeClaim"
    metadata = {
      name      = "llm-cache-pvc"
      namespace = var.kubernetes_namespace
    }
    spec = {
      accessModes = ["ReadWriteOnce"]
      resources = {
        requests = {
          storage = "${local.llm_cache_size}Gi"
        }
      }
      storageClassName = "gp3-retain"
      volumeName       = "llm-cache-pv"
    }
  })

  depends_on = [
    kubectl_manifest.llm_cache_pv,
    kubernetes_namespace.app,
  ]
}
