# All input shaping for the RayService manifest lives here so the apply
# resource (rayservice.tf) stays a one-liner.
#
# common_env: env vars for the Ray head container. The current RAG path runs
# the FastAPI/RAG actor and ONNX embedder on the head node; LLM inference runs
# in the separate vllm-openai workload.

locals {
  common_env = [
    { name = "GRPC_DNS_RESOLVER", value = "native" },
    { name = "HF_HOME", value = "/tmp/huggingface" },
    { name = "EMBEDDER_MODEL_PATH", value = "/models/embedder-onnx-int8" },
    { name = "EMBEDDER_MODEL_ID", value = "intfloat/multilingual-e5-small" },
    { name = "EMBEDDER_NUM_THREADS", value = "1" },
    { name = "EMBEDDER_NUM_CPUS", value = "0.5" },
    { name = "RAG_API_NUM_CPUS", value = "0.2" },
    # P5 — ingest pipeline
    { name = "S3_BUCKET", value = var.s3_bucket },
    { name = "QDRANT_HOST", value = "qdrant-0.qdrant.${var.namespace}.svc.cluster.local" },
    { name = "QDRANT_GRPC_PORT", value = "6334" },
    { name = "QDRANT_COLLECTION", value = "documents" },
    { name = "CHUNK_SIZE_TOKENS", value = "500" },
    { name = "CHUNK_OVERLAP_TOKENS", value = "80" },
    { name = "INGEST_BATCH_SIZE", value = "32" },
    { name = "RAY_SERVE_APP_NAME", value = var.service_name },
    # P6 — QA
    { name = "VLLM_BASE_URL", value = "http://vllm-server-0.vllm-server.${var.namespace}.svc.cluster.local:8000/v1" },
    { name = "VLLM_MAX_MODEL_LEN", value = "4096" },
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
        proxy_location = "HeadOnly"
        http_options = {
          host = "0.0.0.0"
          port = 8000
        }
        applications = [{
          name         = var.service_name
          import_path  = "app.rag_server:rag_app"
          route_prefix = "/"
          deployments = [
            {
              name                 = "RagApi"
              num_replicas         = 1
              max_ongoing_requests = 32
              ray_actor_options = {
                num_cpus = 0.2
              }
            },
            {
              name                 = "Embedder"
              num_replicas         = 1
              max_ongoing_requests = 8
              ray_actor_options = {
                num_cpus = 0.5
              }
            }
          ]
        }]
      })

      rayClusterConfig = {
        rayVersion              = var.ray_version
        enableInTreeAutoscaling = false

        headGroupSpec = {
          rayStartParams = {
            "dashboard-host" = "0.0.0.0"
            "num-cpus"       = "1.5"
          }
          template = {
            spec = {
              # Pin the app pod to the head MNG. The head pod
              # tolerates `ray-role=head` taint set by the head node group.
              nodeSelector = {
                "node-type" = "head"
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

        workerGroupSpecs = []
      }
    }
  }
}
