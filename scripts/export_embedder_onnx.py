#!/usr/bin/env python3
"""
Export intfloat/multilingual-e5-small to ONNX and quantize it to INT8.

This is intended for Docker build time. The runtime image only needs the
resulting ONNX directory plus onnxruntime/tokenizers, not optimum.
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-id", default="intfloat/multilingual-e5-small")
    parser.add_argument("--work-dir", default="/tmp/embedder-onnx")
    parser.add_argument("--out-dir", default="/models/embedder-onnx-int8")
    parser.add_argument(
        "--local-model-dir",
        default="",
        help="path to a pre-downloaded HF model directory (skips HuggingFace download). "
             "Use when building in an environment without outbound HF access.",
    )
    args = parser.parse_args()

    work_dir = Path(args.work_dir)
    out_dir = Path(args.out_dir)
    if work_dir.exists():
        shutil.rmtree(work_dir)
    if out_dir.exists():
        shutil.rmtree(out_dir)
    work_dir.parent.mkdir(parents=True, exist_ok=True)
    out_dir.parent.mkdir(parents=True, exist_ok=True)

    from optimum.exporters.onnx import main_export
    from optimum.onnxruntime import ORTQuantizer
    from optimum.onnxruntime.configuration import AutoQuantizationConfig

    model_source = args.local_model_dir if args.local_model_dir else args.model_id
    print(f"exporting {model_source} -> {work_dir}")
    main_export(
        model_name_or_path=model_source,
        output=work_dir,
        task="feature-extraction",
        device="cpu",
    )

    print(f"quantizing {work_dir} -> {out_dir}")
    quantizer = ORTQuantizer.from_pretrained(work_dir)
    qconfig = AutoQuantizationConfig.avx2(is_static=False, per_channel=True)
    quantizer.quantize(save_dir=out_dir, quantization_config=qconfig)

    # Quantization outputs ONNX weights but may not copy every tokenizer file on
    # older optimum versions. Copy missing tokenizer/config artifacts defensively.
    for source in work_dir.iterdir():
        if source.suffix == ".onnx":
            continue
        destination = out_dir / source.name
        if destination.exists():
            continue
        if source.is_dir():
            shutil.copytree(source, destination)
        else:
            shutil.copy2(source, destination)

    print("done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
