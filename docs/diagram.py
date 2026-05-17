"""Render architecture diagrams from code so they never go stale.

Setup:
    pip install diagrams
    # macOS: brew install graphviz
    # Fedora: sudo dnf install graphviz
    # Ubuntu: sudo apt-get install graphviz

Regenerate:
    cd docs && python diagram.py
"""
from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, EKS
from diagrams.aws.devtools import Codedeploy
from diagrams.aws.management import Cloudwatch, CostExplorer
from diagrams.aws.network import (
    InternetGateway,
    NATGateway,
    PrivateSubnet,
    PublicSubnet,
    VPC,
)
from diagrams.aws.security import IAM, IAMRole
from diagrams.aws.storage import ECR, S3
from diagrams.k8s.compute import Deployment, Pod, ReplicaSet
from diagrams.k8s.controlplane import APIServer
from diagrams.k8s.group import Namespace
from diagrams.k8s.network import SVC, Ingress
from diagrams.k8s.others import CRD
from diagrams.k8s.podconfig import Secret
from diagrams.k8s.rbac import ServiceAccount
from diagrams.onprem.client import Client
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.container import Docker
from diagrams.onprem.gitops import ArgoCD  # noqa: F401  (future)
from diagrams.onprem.monitoring import Grafana, Prometheus

# --- Diagram 1: high-level AWS architecture --------------------------------

with Diagram(
    "LLM Chat — AWS Architecture",
    filename="architecture",
    direction="LR",
    show=False,
    outformat="png",
    graph_attr={"fontsize": "16", "bgcolor": "white"},
):
    user = Client("User\n(laptop)")

    with Cluster("GitHub"):
        gha = GithubActions("Actions\n(OIDC)")

    with Cluster("AWS us-west-2"):
        ecr = ECR("ECR\nllm-chat-dev-ray")
        state = S3("S3\ntfstate (versioned, AES256)")
        budget = CostExplorer("Budget alarm\n$100/month")

        with Cluster("VPC 10.40.0.0/16"):
            igw = InternetGateway("IGW")

            with Cluster("AZ a (workers + NAT)"):
                pub_a = PublicSubnet("public-a")
                nat = NATGateway("NAT GW")
                priv_a = PrivateSubnet("private-a")

            with Cluster("AZ b (control plane only)"):
                pub_b = PublicSubnet("public-b")

            with Cluster("EKS llm-chat-dev (1.30)"):
                api = APIServer("kube-apiserver\n(managed)")

                with Cluster("MNG cpu-workers\nt3.xlarge x 1..4"):
                    ec2 = EC2("Worker node")

                with Cluster("Namespace: kuberay-system"):
                    operator = Deployment("kuberay-operator")

                with Cluster("Namespace: llm-chat"):
                    crd = CRD("RayService")
                    head_svc = SVC("head-svc\n(metrics:8080)")
                    serve_svc = SVC("serve-svc\n(http:8000)")
                    head_pod = Pod("ray-head\n(GCS + proxy)")
                    worker_pod = Pod("ray-worker\n(ChatModel actor)")

                with Cluster("Namespace: monitoring"):
                    prom = Prometheus("Prometheus")
                    graf = Grafana("Grafana\n+ Ray dashboard")

        node_role = IAMRole("Node IAM\nECR pull")
        gh_role = IAMRole("gh-deploy\n(OIDC)")

    # User flow
    user >> Edge(label="port-forward\nor kubectl", color="darkgreen") >> serve_svc
    serve_svc >> head_pod
    head_pod >> Edge(label="Ray RPC", style="dashed") >> worker_pod

    # KubeRay reconciliation
    operator >> Edge(label="watch", style="dashed", color="grey") >> crd
    operator >> Edge(label="create pods", color="grey") >> head_pod
    operator >> worker_pod
    operator >> head_svc
    operator >> serve_svc

    # Image pull
    ec2 >> Edge(label="kubelet pull", style="dashed", color="darkblue") >> ecr
    node_role - ec2

    # CI/CD
    user >> Edge(label="git push") >> gha
    gha >> Edge(label="AssumeRole", color="orange") >> gh_role
    gh_role >> Edge(label="apply", color="orange") >> state
    gha >> Edge(label="docker push", color="orange") >> ecr

    # Monitoring scrape
    prom >> Edge(label="scrape /metrics", style="dashed", color="purple") >> head_svc
    graf >> Edge(style="dotted", color="purple") >> prom

    # Budget watches everything tagged Project=llm-chat
    budget >> Edge(style="dotted", color="brown") >> ecr
    budget >> Edge(style="dotted", color="brown") >> ec2


# --- Diagram 2: request path -----------------------------------------------

with Diagram(
    "LLM Chat — Request Path",
    filename="request_flow",
    direction="LR",
    show=False,
    outformat="png",
    graph_attr={"fontsize": "16", "bgcolor": "white"},
):
    client = Client("Client")
    svc = SVC("Service:8000\n(ClusterIP)")
    proxy = Pod("Ray Serve\nHTTP Proxy\n(head)")
    replica = Pod("ChatModel\nReplica\n(worker)")

    (
        client
        >> Edge(label="POST /chat", color="darkgreen")
        >> svc
        >> Edge(label="kube-proxy", style="dashed")
        >> proxy
        >> Edge(label="Ray RPC\n(actor call)", color="blue")
        >> replica
    )

    replica >> Edge(label="HF model\nin-memory", style="dotted") >> Edge(label="answer", color="darkred") >> proxy
    proxy >> Edge(label="JSON response", color="darkred") >> client


# --- Diagram 3: autoscale loop ---------------------------------------------

with Diagram(
    "LLM Chat — Autoscale Cascade",
    filename="autoscale",
    direction="TB",
    show=False,
    outformat="png",
    graph_attr={"fontsize": "16", "bgcolor": "white"},
):
    with Cluster("Trigger"):
        load = Client("Concurrent\nrequests")

    with Cluster("Layer 1 — Ray Serve"):
        proxy = Pod("Serve Proxy\n(ongoing_requests / replica)")
        rsa = Pod("Serve Autoscaler\n(target=1.0,\nupscale_delay=10s)")

    with Cluster("Layer 2 — Ray cluster"):
        ray_auto = Pod("Ray Autoscaler\n(request worker pod)")

    with Cluster("Layer 3 — KubeRay"):
        kubescale = ReplicaSet("Worker ReplicaSet\n(maxReplicas=3)")

    with Cluster("Layer 4 — Cluster Autoscaler / MNG"):
        mng = EC2("MNG (1..4)\nadd EC2 if needed")

    load >> proxy
    proxy >> Edge(label="metric") >> rsa
    rsa >> Edge(label="scale +1 replica") >> ray_auto
    ray_auto >> Edge(label="add pod") >> kubescale
    kubescale >> Edge(label="pod pending\nno node") >> mng
    mng >> Edge(label="new EC2\n+ kubelet join", style="dashed", color="darkgreen") >> kubescale
