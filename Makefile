.PHONY: setup models project open

setup: models project

models:
	./scripts/download_models.sh s2

project:
	xcodegen generate

open: project
	open MomentFinder.xcodeproj
