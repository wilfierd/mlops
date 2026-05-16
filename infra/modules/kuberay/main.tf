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

locals {
  common_env = [
    { name = "MODEL_ID", value = var.model_id },
    { name = "MODEL_DTYPE", value = var.model_dtype },
    { name = "ENABLE_THINKING", value = "false" },
    { name = "MAX_NEW_TOKENS", value = "160" },
    { name = "MAX_INPUT_TOKENS", value = "2048" },
    { name = "TORCH_NUM_THREADS", value = tostring(var.replica_cpus) },
    { name = "MODEL_NUM_CPUS", value = tostring(var.replica_cpus) },
    { name = "MAX_ONGOING_REQUESTS", value = "1" },
    { name = "GRPC_DNS_RESOLVER", value = "native" },
    { name = "HF_HOME", value = "/tmp/huggingface" },
  ]

  rayservice = {
    apiVersion = "ray.io/v1"
    kind       = "RayService"
    metadata = {
      name      = var.service_name
      namespace = var.namespace
    }
    spec = {
      serviceUnhealthySecondThreshold    = 900
      deploymentUnhealthySecondThreshold = 300

      serveConfigV2 = yamlencode({
        proxy_location = "EveryNode"
        http_options = {
          host = "0.0.0.0"
          port = 8000
        }
        applications = [{
          name         = var.service_name
          import_path  = "app.server:chat_app"
          route_prefix = "/"
          deployments = [{
            name                 = "ChatModel"
            max_ongoing_requests = 1
            autoscaling_config = {
              min_replicas            = var.min_replicas
              initial_replicas        = var.min_replicas
              max_replicas            = var.max_replicas
              target_ongoing_requests = 1
              upscale_delay_s         = 10
              downscale_delay_s       = 120
            }
            ray_actor_options = {
              num_cpus = var.replica_cpus
            }
          }]
        }]
      })

      rayClusterConfig = {
        rayVersion              = var.ray_version
        enableInTreeAutoscaling = true
        autoscalerOptions = {
          upscalingMode      = "Default"
          idleTimeoutSeconds = 120
        }

        headGroupSpec = {
          rayStartParams = {
            "dashboard-host" = "0.0.0.0"
            "num-cpus"       = "0"
          }
          template = {
            spec = {
              containers = [{
                name            = "ray-head"
                image           = var.image
                imagePullPolicy = "IfNotPresent"
                ports = [
                  { containerPort = 6379, name = "gcs" },
                  { containerPort = 8265, name = "dashboard" },
                  { containerPort = 10001, name = "client" },
                  { containerPort = 8000, name = "serve" },
                ]
                env = local.common_env
                resources = {
                  requests = { cpu = var.head_cpu_request, memory = var.head_memory_request }
                  limits   = { cpu = var.head_cpu_limit, memory = var.head_memory_limit }
                }
                volumeMounts = [{ name = "hf-cache", mountPath = "/tmp/huggingface" }]
              }]
              volumes = [{ name = "hf-cache", emptyDir = {} }]
            }
          }
        }

        workerGroupSpecs = [{
          groupName      = "cpu-workers"
          minReplicas    = var.min_replicas
          maxReplicas    = var.max_replicas
          rayStartParams = {}
          template = {
            spec = {
              terminationGracePeriodSeconds = 60
              containers = [{
                name            = "ray-worker"
                image           = var.image
                imagePullPolicy = "IfNotPresent"
                env             = local.common_env
                resources = {
                  requests = { cpu = var.worker_cpu_request, memory = var.worker_memory_request }
                  limits   = { cpu = var.worker_cpu_limit, memory = var.worker_memory_limit }
                }
                volumeMounts = [{ name = "hf-cache", mountPath = "/tmp/huggingface" }]
              }]
              volumes = [{ name = "hf-cache", emptyDir = {} }]
            }
          }
        }]
      }
    }
  }
}

# kubectl_manifest applies at apply-time (no plan-time API call), so it works
# on a fresh `terraform apply` against a brand-new EKS cluster.
resource "kubectl_manifest" "rayservice" {
  yaml_body = yamlencode(local.rayservice)

  server_side_apply = true
  wait              = false

  depends_on = [
    helm_release.kuberay_operator,
    kubernetes_namespace.app,
  ]
}
