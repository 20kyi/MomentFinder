#!/usr/bin/env python3
"""InsightFace 얼굴 인식 모델(MobileFaceNet, w600k_mbf)을 Core ML 로 변환합니다.

입력은 ArcFace 기준점으로 정렬한 112x112 RGB 얼굴, 출력은 512차원 임베딩입니다.
InsightFace 사전학습 가중치는 비상업적 연구 용도로만 쓸 수 있습니다 (https://github.com/deepinsight/insightface#license).
앱을 상업적으로 배포하려면 상업 라이선스를 받거나 다른 가중치로 바꿔야 합니다.

Makefile 의 face-model 타깃이 버전을 고정한 가상환경을 만들어 실행합니다.
"""

import io
import sys
import urllib.request
import zipfile
from pathlib import Path

import coremltools as ct
import numpy as np
import onnx
import torch
from onnx2torch import convert
from PIL import Image

URL = "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_s.zip"
MEMBER = "w600k_mbf.onnx"
ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "MomentFinder" / "Resources" / "Models" / "face_mbf.mlpackage"
CACHE = ROOT / "build" / MEMBER


def fetch_onnx() -> Path:
    if CACHE.exists():
        return CACHE
    print(f"fetch {URL}")
    with urllib.request.urlopen(URL) as response:
        archive = zipfile.ZipFile(io.BytesIO(response.read()))
    name = next(n for n in archive.namelist() if n.endswith(MEMBER))
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_bytes(archive.read(name))
    return CACHE


def main() -> None:
    if DEST.exists():
        print(f"skip  {DEST}")
        return

    onnx_model = onnx.load(str(fetch_onnx()))
    torch_model = convert(onnx_model).eval()
    example = torch.rand(1, 3, 112, 112) * 2 - 1
    traced = torch.jit.trace(torch_model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(
            name="image",
            shape=example.shape,
            scale=1 / 127.5,
            bias=[-1.0, -1.0, -1.0],
            color_layout=ct.colorlayout.RGB,
        )],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = "InsightFace w600k_mbf (MobileFaceNet) face embedding, non-commercial license"

    with torch.no_grad():
        reference = traced(example).numpy().ravel()
    pixels = ((example[0].permute(1, 2, 0).numpy() + 1) * 127.5).round().clip(0, 255).astype(np.uint8)
    predicted = mlmodel.predict({"image": Image.fromarray(pixels)})["embedding"].ravel()
    cosine = float(np.dot(reference, predicted) / (np.linalg.norm(reference) * np.linalg.norm(predicted)))
    print(f"torch vs coreml cosine: {cosine:.4f}")
    if cosine < 0.99:
        sys.exit("변환 결과가 원본과 다릅니다.")

    DEST.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(DEST))
    print(f"done -> {DEST}")


if __name__ == "__main__":
    main()
