ARG RAY_VERSION=2.55.1
FROM rayproject/ray:${RAY_VERSION}-py311-cpu

# Build-time knobs. Override via `docker build --build-arg`.
ARG MODEL_ID=Qwen/Qwen3-0.6B
ARG PRELOAD_MODEL=false
ARG INFERENCE_BACKEND=llamacpp
ARG GGUF_REPO_ID=bartowski/Qwen_Qwen3-0.6B-GGUF
ARG GGUF_FILENAME=Qwen_Qwen3-0.6B-Q4_K_M.gguf

ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/serve \
    HF_HOME=/tmp/huggingface \
    TRANSFORMERS_CACHE=/tmp/huggingface \
    MODEL_ID=${MODEL_ID} \
    INFERENCE_BACKEND=${INFERENCE_BACKEND} \
    GGUF_REPO_ID=${GGUF_REPO_ID} \
    GGUF_FILENAME=${GGUF_FILENAME}

WORKDIR /serve

# llama-cpp-python often falls back to source build on aarch64 because the
# prebuilt manylinux wheel doesn't always match the base image's Python ABI.
# Install gcc/g++/cmake as system packages so the fallback compile works.
# Conda's compiler_compat shim ($CC=.../compiler_compat) is broken on aarch64
# in the rayproject base image, so unset CC/CXX to let scikit-build-core
# discover the system compiler.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential cmake \
 && rm -rf /var/lib/apt/lists/*
USER ray
ENV CC= CXX=

COPY requirements.txt .

# Install torch (CPU-only wheel) first so the resolver doesn't pull the 2GB
# nvidia/CUDA wheels by accident.
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.7.1

# llama-cpp-python: prefer prebuilt wheel, fallback to source build (which
# now works thanks to the build-essential install above). Build is ~5 min
# on ARM via QEMU emulation.
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY scripts ./scripts

# Pre-download the active backend's model into the layer so pod cold start
# doesn't pay the HF download cost (saves ~30-90s per replica spawn).
RUN if [ "$PRELOAD_MODEL" = "true" ]; then \
      if [ "$INFERENCE_BACKEND" = "llamacpp" ]; then \
        echo "preload GGUF: ${GGUF_REPO_ID} / ${GGUF_FILENAME}"; \
        python -c "from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='${GGUF_REPO_ID}', filename='${GGUF_FILENAME}')"; \
      else \
        echo "preload Transformers safetensors: ${MODEL_ID}"; \
        python -c "from transformers import AutoModelForCausalLM, AutoTokenizer; AutoTokenizer.from_pretrained('${MODEL_ID}'); AutoModelForCausalLM.from_pretrained('${MODEL_ID}')"; \
      fi; \
    fi
