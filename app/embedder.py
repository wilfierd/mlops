from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Literal


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if not raw:
        return default
    return int(raw)


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if not raw:
        return default
    return float(raw)


def _env_str(name: str, default: str) -> str:
    return os.getenv(name, default)


def _find_onnx_model(model_dir: Path) -> Path:
    candidates = [
        model_dir / "model_quantized.onnx",
        model_dir / "model.onnx",
    ]
    candidates.extend(sorted(model_dir.glob("*.onnx")))
    for path in candidates:
        if path.is_file():
            return path
    raise FileNotFoundError(f"no ONNX model found under {model_dir}")


class E5OnnxEmbedder:
    """CPU ONNX embedder for intfloat/multilingual-e5-small.

    The runtime artifacts are expected to be baked into the app image. Keeping
    model loading here lazy/import-local lets normal unit checks run without
    onnxruntime installed on the developer machine.
    """

    def __init__(self) -> None:
        import numpy as np
        import onnxruntime as ort
        from tokenizers import Tokenizer

        self._np = np
        self.model_dir = Path(_env_str("EMBEDDER_MODEL_PATH", "/models/embedder-onnx-int8"))
        self.model_file = _find_onnx_model(self.model_dir)
        self.tokenizer_file = self.model_dir / "tokenizer.json"
        if not self.tokenizer_file.is_file():
            raise FileNotFoundError(f"tokenizer.json not found under {self.model_dir}")

        self.model_id = _env_str("EMBEDDER_MODEL_ID", "intfloat/multilingual-e5-small")
        self.dim = _env_int("EMBEDDER_DIM", 384)
        self.max_length = _env_int("EMBEDDER_MAX_LENGTH", 512)
        self.query_prefix = _env_str("EMBEDDER_PREFIX_QUERY", "query: ")
        self.passage_prefix = _env_str("EMBEDDER_PREFIX_PASSAGE", "passage: ")
        self.normalize = _env_str("EMBEDDER_NORMALIZE", "true").lower() == "true"

        opts = ort.SessionOptions()
        opts.intra_op_num_threads = _env_int("EMBEDDER_NUM_THREADS", 1)
        opts.inter_op_num_threads = 1
        opts.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
        opts.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL

        self.session = ort.InferenceSession(
            str(self.model_file),
            sess_options=opts,
            providers=["CPUExecutionProvider"],
        )
        self.input_names = {meta.name for meta in self.session.get_inputs()}

        self.tokenizer = Tokenizer.from_file(str(self.tokenizer_file))
        self.tokenizer.enable_truncation(max_length=self.max_length)
        pad_id = self.tokenizer.token_to_id("[PAD]")
        if pad_id is None:
            pad_id = 0
        self.tokenizer.enable_padding(pad_id=pad_id, pad_token="[PAD]")

    def _with_prefix(self, text: str, input_type: Literal["query", "passage", "raw"]) -> str:
        if input_type == "raw":
            return text
        if input_type not in ("query", "passage"):
            raise ValueError(f"unknown input_type: {input_type!r}; expected 'query', 'passage', or 'raw'")
        if text.startswith(self.query_prefix) or text.startswith(self.passage_prefix):
            return text
        if input_type == "query":
            return f"{self.query_prefix}{text}"
        return f"{self.passage_prefix}{text}"

    def embed(
        self,
        texts: list[str],
        input_type: Literal["query", "passage", "raw"] = "query",
    ) -> tuple[list[list[float]], float]:
        started = time.perf_counter()
        normalized_texts = [self._with_prefix(text, input_type) for text in texts]
        encodings = self.tokenizer.encode_batch(normalized_texts)

        input_ids = self._np.asarray([encoding.ids for encoding in encodings], dtype=self._np.int64)
        attention_mask = self._np.asarray(
            [encoding.attention_mask for encoding in encodings],
            dtype=self._np.int64,
        )
        inputs = {
            "input_ids": input_ids,
            "attention_mask": attention_mask,
        }
        if "token_type_ids" in self.input_names:
            inputs["token_type_ids"] = self._np.asarray(
                [encoding.type_ids for encoding in encodings],
                dtype=self._np.int64,
            )

        token_embeddings = self.session.run(None, inputs)[0]
        mask = attention_mask[..., None].astype(self._np.float32)
        summed = (token_embeddings * mask).sum(axis=1)
        counts = self._np.clip(mask.sum(axis=1), a_min=1e-9, a_max=None)
        vectors = summed / counts

        if self.normalize:
            norms = self._np.linalg.norm(vectors, axis=1, keepdims=True)
            vectors = vectors / self._np.clip(norms, a_min=1e-12, a_max=None)

        elapsed_ms = (time.perf_counter() - started) * 1000.0
        return vectors.astype(self._np.float32).tolist(), elapsed_ms
