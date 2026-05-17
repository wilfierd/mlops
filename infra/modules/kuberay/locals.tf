# All input shaping for the RayService manifest lives here so the apply
# resource (rayservice.tf) stays a one-liner.
#
# common_env: env vars shared by head and worker containers. GRPC_DNS_RESOLVER
# in particular is required to avoid Ray's c-ares resolver bug against
# CoreDNS — without it workers fail to connect to GCS during cold start.

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
                  # Ray exports Prometheus metrics on 8080 via the
                  # `--metrics-export-port=8080` flag KubeRay sets by default.
                  # Declare here so the auto-generated head Service has a
                  # named port `metrics` for ServiceMonitor to scrape.
                  { containerPort = 8080, name = "metrics" },
                ]
                env = local.common_env
                resources = {
                  requests = { cpu = var.head_cpu_request, memory = var.head_memory_request }
                  limits   = { cpu = var.head_cpu_limit, memory = var.head_memory_limit }
                }
                # Head exposes Serve HTTP proxy. Readiness gate on /-/healthz
                # ensures the K8s service only routes to head when the proxy is up.
                readinessProbe = {
                  httpGet             = { path = "/-/healthz", port = 8000 }
                  initialDelaySeconds = 20
                  periodSeconds       = 10
                  timeoutSeconds      = 5
                  failureThreshold    = 3
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
                # Worker hosts the ChatModel actor. /-/healthz on 8000 returns 200
                # only when the Serve replica has loaded the model.
                # Works because proxy_location=EveryNode places a proxy on every
                # pod; switch to tcpSocket on raylet port if you flip to HeadOnly.
                readinessProbe = {
                  httpGet             = { path = "/-/healthz", port = 8000 }
                  initialDelaySeconds = 30
                  periodSeconds       = 10
                  timeoutSeconds      = 5
                  failureThreshold    = 3
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
