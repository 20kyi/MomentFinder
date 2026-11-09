#!/usr/bin/env bash
# MobileCLIP Core ML 모델과 CLIP 토크나이저 파일을 내려받습니다.
set -euo pipefail

VARIANT="${1:-s2}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/MomentFinder/Resources/Models"
HF="https://huggingface.co"

mkdir -p "$DEST"

download() {
  local url="$1" out="$2"
  if [[ -s "$out" ]]; then
    echo "skip  $out"
    return
  fi
  mkdir -p "$(dirname "$out")"
  echo "fetch $url"
  curl -fsSL --retry 3 -o "$out.part" "$url"
  mv "$out.part" "$out"
}

for kind in image text; do
  pkg="mobileclip_${VARIANT}_${kind}.mlpackage"
  for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    download "$HF/apple/coreml-mobileclip/resolve/main/$pkg/$f" "$DEST/$pkg/$f"
  done
done

download "$HF/openai/clip-vit-base-patch32/resolve/main/vocab.json" "$DEST/clip-vocab.json"
download "$HF/openai/clip-vit-base-patch32/resolve/main/merges.txt" "$DEST/clip-merges.txt"

echo "done -> $DEST"
