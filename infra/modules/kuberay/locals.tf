# All input shaping for the RayService manifest lives here so the apply
# resource (rayservice.tf) stays a one-liner.
#
# common_env: env vars shared by head and worker containers. GRPC_DNS_RESOLVER
# in particular is required to avoid Ray's c-ares resolver bug against
# CoreDNS — without it workers fail to connect to GCS during cold start.

locals {
  # KubeRay workerGroupSpec.minReplicas controls POD count (K8s pods),
  # while Ray Serve autoscaling_config.min_replicas controls ACTOR count
  # (Python instances). Multiple actors can pack into one pod, so the
  # two are NOT the same number.
  #
  # Example: min_replicas=2 actors with actors_per_pod=2 -> need only 1 pod.
  worker_pod_min = max(1, ceil(var.min_replicas / var.actors_per_pod))
  worker_pod_max = max(1, ceil(var.max_replicas / var.actors_per_pod))

  common_env = [
    # Backend selection — llamacpp uses GGUF Q4_K_M, transformers uses bf16
    { name = "INFERENCE_BACKEND", value = var.inference_backend },
    { name = "MODEL_ID", value = var.model_id },
    { name = "MODEL_DTYPE", value = var.model_dtype },

    # llamacpp-specific
    { name = "GGUF_REPO_ID", value = var.gguf_repo_id },
    { name = "GGUF_FILENAME", value = var.gguf_filename },
    { name = "LLAMA_N_CTX", value = tostring(var.llama_n_ctx) },
    { name = "LLAMA_N_BATCH", value = tostring(var.llama_n_batch) },
    # Thread count must be INTEGER (llama.cpp + torch.set_num_threads).
    # Ray `num_cpus` accepts fractional (1.5) but OS threads cannot — round UP
    # so each actor uses 2 OS threads when reserved 1.5 Ray CPU. Kernel
    # scheduler handles contention; total threads ≤ pod CPU limit.
    { name = "LLAMA_N_THREADS", value = tostring(ceil(var.replica_cpus)) },
    { name = "TORCH_NUM_THREADS", value = tostring(ceil(var.replica_cpus)) },

    # Shared
    { name = "ENABLE_THINKING", value = "false" },
    { name = "MAX_NEW_TOKENS", value = "160" },
    { name = "MAX_INPUT_TOKENS", value = "2048" },
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
              # Pin head pod to the head MNG (t4g.large). The head pod
              # tolerates `ray-role=head` taint set by the head node group.
              nodeSelector = {
                "ray.io/node-type" = "head"
              }
              tolerations = [{
                key      = "ray-role"
                operator = "Equal"
                value    = "head"
                effect   = "NoSchedule"
              }]
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
                # RayService submits Serve only after the head pod is Ready.
                # Do not probe Serve /-/healthz here, otherwise bootstrap
                # deadlocks: Serve is not started until this probe passes.
                readinessProbe = {
                  httpGet             = { path = "/api/healthz", port = 52365 }
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
          groupName = "cpu-workers"
          # ⚠️ minReplicas / maxReplicas here = POD count, NOT actor count.
          # Ray packs `actors_per_pod` actors per worker pod (see locals).
          minReplicas    = local.worker_pod_min
          maxReplicas    = local.worker_pod_max
          rayStartParams = {}
          template = {
            spec = {
              terminationGracePeriodSeconds = 60
              # Pin worker pods to the worker MNG (m7g.xlarge). The head MNG
              # has a NoSchedule taint so workers naturally avoid it.
              nodeSelector = {
                "ray.io/node-type" = "worker"
              }
              containers = [{
                name            = "ray-worker"
                image           = var.image
                imagePullPolicy = "IfNotPresent"
                env             = local.common_env
                resources = {
                  requests = { cpu = var.worker_cpu_request, memory = var.worker_memory_request }
                  limits   = { cpu = var.worker_cpu_limit, memory = var.worker_memory_limit }
                }
                # Worker readiness should mean the Ray node joined the cluster.
                # Serve app health is checked by RayService/Serve separately.
                readinessProbe = {
                  httpGet             = { path = "/api/healthz", port = 52365 }
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
