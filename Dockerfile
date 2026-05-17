ARG RAY_VERSION=2.55.1
FROM rayproject/ray:${RAY_VERSION}-py311-cpu

# Build-time knobs. Override via `docker build --build-arg`.
ARG MODEL_ID=Qwen/Qwen3-0.6B
ARG PRELOAD_MODEL=false
ARG INFERENCE_BACKEND=llamacpp
ARG GGUF_REPO_ID=Qwen/Qwen3-0.6B-GGUF
ARG GGUF_FILENAME=Qwen3-0.6B-Q4_K_M.gguf

ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/serve \
    HF_HOME=/tmp/huggingface \
    TRANSFORMERS_CACHE=/tmp/huggingface \
    MODEL_ID=${MODEL_ID} \
    INFERENCE_BACKEND=${INFERENCE_BACKEND} \
    GGUF_REPO_ID=${GGUF_REPO_ID} \
    GGUF_FILENAME=${GGUF_FILENAME}

WORKDIR /serve

COPY requirements.txt .

# Install torch (CPU-only wheel) first so the resolver doesn't pull the 2GB
# nvidia/CUDA wheels by accident.
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.7.1

# llama-cpp-python wheel build on ARM under QEMU is slow (~10 min). The
# upstream provides a manylinux2_28_aarch64 wheel for recent versions, so
# pip should pick it up without compilation. If you bump the version and
# notice a long build, pin to a version with prebuilt aarch64 wheels.
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
