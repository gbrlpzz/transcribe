# Transcribe — fully local dictation & transcription for Prime Agent

PYTHON ?= .venv/bin/python
PIP     ?= .venv/bin/pip

.PHONY: help venv install app skill test doctor clean

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

venv: ## create the virtualenv and install the package (editable) + dev deps
	uv venv --python 3.11 .venv
	uv pip install --python .venv -e ".[dev]"

install: ## install engine + skill for the current user (recommended path)
	uv tool install .
	@echo "→ installing Prime Agent skill…"
	@bash scripts/install-skill.sh

app: ## build the native menu-bar app into app/dist/Transcribe.app
	bash app/build.sh

app-install: app ## build + copy the app to /Applications
	rm -rf /Applications/Transcribe.app
	cp -R app/dist/Transcribe.app /Applications/
	@echo "✓ Transcribe.app installed — launch it from Spotlight"

test: ## run the unit tests
	.venv/bin/pytest -q

doctor: ## diagnose the local setup
	.venv/bin/transcribe doctor

clean: ## remove sessions older than the TTL
	.venv/bin/transcribe clean
