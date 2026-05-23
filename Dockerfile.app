ARG RAY_VERSION=2.55.1

FROM python:3.11-slim AS embedder-builder

ENV PYTHONUNBUFFERED=1 \
    HF_HOME=/tmp/huggingface

WORKDIR /build

COPY requirements-embedder-build.txt .
COPY scripts/export_embedder_onnx.py ./scripts/export_embedder_onnx.py

# CPU torch is only needed in the build stage for ONNX export.
# NOTE: this RUN downloads intfloat/multilingual-e5-small from HuggingFace (~470 MB).
# For offline builds: pass --local-model-dir to export_embedder_onnx.py pointing at
# a pre-downloaded model dir (e.g. COPY ./local-models/e5-small /tmp/e5-local).
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu "torch>=2.4.0,<3.0.0"
RUN pip install --no-cache-dir -r requirements-embedder-build.txt
RUN python scripts/export_embedder_onnx.py \
    --model-id intfloat/multilingual-e5-small \
    --work-dir /tmp/embedder-onnx \
    --out-dir /models/embedder-onnx-int8

FROM rayproject/ray:${RAY_VERSION}-py311-cpu

ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/serve \
    HF_HOME=/tmp/huggingface \
    EMBEDDER_MODEL_PATH=/models/embedder-onnx-int8 \
    EMBEDDER_MODEL_ID=intfloat/multilingual-e5-small \
    EMBEDDER_NUM_THREADS=1 \
    EMBEDDER_NUM_CPUS=0.5 \
    RAG_API_NUM_CPUS=0.2

WORKDIR /serve

COPY requirements-app.txt .
RUN pip install --no-cache-dir -r requirements-app.txt

COPY --from=embedder-builder /models/embedder-onnx-int8 /models/embedder-onnx-int8
COPY app ./app
COPY scripts ./scripts
