#!/usr/bin/env python3
"""Convert all-MiniLM-L6-v2 to a fixed-length FP16 Core ML encoder.

Run from a Python 3.11 venv. Version matrix is load-bearing — newer torch/transformers
break coremltools' torch frontend (verified 2026-07-10):
  python -m pip install "torch==2.7.0" "numpy<2.3" "transformers==4.49.0" \
      "sentence-transformers==3.4.1" coremltools
  python tools/retrieval-eval/convert_minilm.py
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from sentence_transformers import SentenceTransformer
from transformers import AutoModel, AutoTokenizer

MODEL_ID = "sentence-transformers/all-MiniLM-L6-v2"
SEQUENCE_LENGTH = 256
SENTENCES = [
    "A short sentence.",
    "The quick brown fox jumps over the lazy dog.",
    "Forth keeps parameters on a data stack and return addresses on another stack.",
    "Unicode stays meaningful: café, naïve, 東京, and a tiny rocket 🚀.",
    "A considerably longer reference sentence verifies that attention-mask-weighted mean pooling ignores padding tokens while preserving the meaning distributed across every real token in the input.",
]


class Encoder(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(
        self, input_ids: torch.Tensor, attention_mask: torch.Tensor, token_type_ids: torch.Tensor
    ) -> torch.Tensor:
        return self.model(
            input_ids=input_ids.long(),
            attention_mask=attention_mask.long(),
            token_type_ids=token_type_ids.long(),
            return_dict=False,
        )[0]


def main() -> None:
    if sys.prefix == sys.base_prefix:
        raise SystemExit("Run this script inside a Python venv")

    root = Path(__file__).resolve().parents[2]
    output = root / "Sources/Ticker/Resources/MiniLM"
    output.mkdir(parents=True, exist_ok=True)

    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    torch_model = AutoModel.from_pretrained(MODEL_ID).eval()
    sample = tokenizer(
        "trace input",
        max_length=SEQUENCE_LENGTH,
        padding="max_length",
        truncation=True,
        return_tensors="pt",
    )
    traced = torch.jit.trace(
        Encoder(torch_model),
        (sample["input_ids"], sample["attention_mask"], sample["token_type_ids"]),
        strict=False,
    )
    shape = (1, SEQUENCE_LENGTH)
    package = Path(__file__).parent / "MiniLM.mlpackage"
    compiled = output / "MiniLM.mlmodelc"
    shutil.rmtree(package, ignore_errors=True)
    shutil.rmtree(compiled, ignore_errors=True)
    model = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.TensorType(name="input_ids", shape=shape, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=shape, dtype=np.int32),
            ct.TensorType(name="token_type_ids", shape=shape, dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="token_embeddings")],
    )
    model.short_description = MODEL_ID
    model.version = "1"
    model.save(package)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(output)], check=True)

    tokenizer.save_vocabulary(str(output))  # writes vocab.txt
    references = SentenceTransformer(MODEL_ID).encode(
        SENTENCES, normalize_embeddings=True, convert_to_numpy=True
    )
    payload = {
        "modelId": MODEL_ID,
        "sequenceLength": SEQUENCE_LENGTH,
        "sentences": [
            {"text": text, "embedding": vector.astype(float).tolist()}
            for text, vector in zip(SENTENCES, references)
        ],
    }
    (Path(__file__).parent / "reference-vectors.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Wrote {package}, {compiled}, vocab.txt, and reference-vectors.json")


if __name__ == "__main__":
    main()
