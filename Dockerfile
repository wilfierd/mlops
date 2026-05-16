ARG RAY_VERSION=2.55.1
FROM rayproject/ray:${RAY_VERSION}-py311-cpu

ARG MODEL_ID=Qwen/Qwen3-0.6B
ARG PRELOAD_MODEL=false

ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/serve \
    HF_HOME=/tmp/huggingface \
    TRANSFORMERS_CACHE=/tmp/huggingface \
    MODEL_ID=${MODEL_ID}

WORKDIR /serve

COPY requirements.txt .
# Cai torch CPU-only truoc de tranh tai 2GB nvidia/CUDA wheels (may CPU khong dung).
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.7.1
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY scripts ./scripts

RUN if [ "$PRELOAD_MODEL" = "true" ]; then \
      python -c "from transformers import AutoModelForCausalLM, AutoTokenizer; import os; m=os.environ['MODEL_ID']; AutoTokenizer.from_pretrained(m); AutoModelForCausalLM.from_pretrained(m)"; \
    fi
