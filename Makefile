# Transcribe — fully local dictation & transcription for Prime Agent

PYTHON ?= .venv/bin/python
PIP     ?= .venv/bin/pip

.PHONY: help venv install app app-install quick-action-install skill daemon daemon-install daemon-test test doctor clean

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

venv: ## create the virtualenv and install the package (editable) + dev deps
	uv venv --python 3.11 .venv
	uv pip install --python .venv -e ".[dev]"

BACKEND_FLAG ?= $(shell [ "$$(uname -s)" = "Darwin" ] && [ "$$(uname -m)" = "arm64" ] && echo "--with mlx==0.32.1 --with mlx-whisper==0.4.3" || echo "--with faster-whisper")

install: ## install engine, daemon, LaunchAgents, Quick Action, and skill
	@bash scripts/install-macos.sh

app: ## build the native menu-bar app into app/dist/Transcribe.app
	bash app/build.sh

app-install: app quick-action-install ## build + install the app and Finder Quick Action
	rm -rf /Applications/Transcribe.app
	cp -R app/dist/Transcribe.app /Applications/
	@echo "✓ Transcribe.app installed — launch it from Spotlight"

quick-action-install: ## install the Finder right-click action
	mkdir -p "$(HOME)/Library/Services"
	rm -rf "$(HOME)/Library/Services/Transcribe.workflow"
	cp -R Transcribe.workflow "$(HOME)/Library/Services/"
	@echo "✓ Finder Quick Action installed — use Finder → Quick Actions → Transcribe"

daemon: ## build the Zig capture daemon (ReleaseFast)
	cd daemon && zig build -Doptimize=ReleaseFast

daemon-install: ## install the daemon and reload its LaunchAgents
	@bash scripts/install-macos.sh

daemon-test: ## run daemon unit tests
	cd daemon && zig build test

test: ## run the unit tests
	.venv/bin/pytest -q

doctor: ## diagnose the local setup
	.venv/bin/transcribe doctor

clean: ## remove sessions older than the TTL
	.venv/bin/transcribe clean
