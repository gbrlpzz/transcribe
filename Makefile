# Transcribe Leggerissimo — native dictation & file transcription for macOS 26

.PHONY: help app app-install quick-action-install dist test

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

app: ## build the app into app/dist/Transcribe.app
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

VERSION ?= $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' app/Resources/Info.plist)

test: ## run the executable test battery (cd app; no XCTest needed)
	cd app && swift run -c release TranscribeCoreTests

dist: app ## build the release zip to attach to a GitHub release
	mkdir -p release
	rm -f release/Transcribe-$(VERSION).zip
	ditto -c -k --norsrc --keepParent --zlibCompressionLevel 9 app/dist/Transcribe.app release/Transcribe-$(VERSION).zip
	@echo "✓ release/Transcribe-$(VERSION).zip — attach this to the GitHub release for tag v$(VERSION)"
