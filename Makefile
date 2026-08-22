# Transcribe — fully local dictation & transcription for Apple Silicon Macs

PYTHON ?= .venv/bin/python

.PHONY: help venv install app app-install quick-action-install skill test doctor clean dist

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

venv: ## create the virtualenv and install the package (editable) + dev deps
	uv venv --python 3.11 .venv
	uv pip install --python .venv -e ".[dev]"

install: ## install engine + skill for the current user
	uv tool install --force --reinstall .
	@echo "→ installing Prime Agent skill…"
	@bash scripts/install-skill.sh

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

test: ## run the unit tests
	.venv/bin/pytest -q

doctor: ## diagnose the local setup
	.venv/bin/transcribe doctor

clean: ## remove sessions older than the TTL
	.venv/bin/transcribe clean

VERSION ?= $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/Resources/Info.plist)

dist: app ## build the release zip to attach to a GitHub release
	mkdir -p release
	rm -f release/Transcribe-$(VERSION).zip
	# --norsrc keeps Finder/metadata AppleDouble entries (__MACOSX/) out of the
	# zip; codesign signatures live in _CodeSignature + the Mach-O and survive.
	ditto -c -k --norsrc --keepParent app/dist/Transcribe.app release/Transcribe-$(VERSION).zip
	@echo "✓ release/Transcribe-$(VERSION).zip — attach this to the GitHub release for tag v$(VERSION)"
