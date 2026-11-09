.PHONY: setup models face-model icon project open

VENV := build/model-venv
# coremltools 의 네이티브 모듈(mlpackage 저장)이 최신 Python 에는 아직 없어 macOS 기본 Python 3.9 를 씁니다.
MODEL_PYTHON ?= /usr/bin/python3

setup: models project

models: face-model
	./scripts/download_models.sh s2

face-model:
	@test -x $(VENV)/bin/python || ($(MODEL_PYTHON) -m venv $(VENV) && $(VENV)/bin/pip install -q "coremltools==8.3.0" "torch==2.7.0" "onnx<1.18" onnx2torch "numpy<2" pillow)
	$(VENV)/bin/python scripts/convert_face_model.py

icon:
	python3 scripts/render_app_icon.py

project:
	xcodegen generate

open: project
	open MomentFinder.xcodeproj
