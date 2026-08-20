"""Regression checks for the Finder Automator Quick Action bundle."""

from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / "Transcribe.workflow" / "Contents"
APP_INFO = ROOT / "app" / "Resources" / "Info.plist"


def test_quick_action_declares_a_runner_compatible_file_type():
    info = plistlib.loads((WORKFLOW / "Info.plist").read_bytes())
    document = plistlib.loads((WORKFLOW / "document.wflow").read_bytes())

    service = info["NSServices"][0]
    assert service["NSMessage"] == "runWorkflowAsService"
    assert service["NSSendFileTypes"] == ["public.audio", "public.movie"]
    assert (
        document["workflowMetaData"]["serviceInputTypeIdentifier"]
        == "com.apple.Automator.fileSystemObject.music"
    )


def test_quick_action_routes_to_the_native_file_status_hud():
    info = plistlib.loads(APP_INFO.read_bytes())
    schemes = [
        scheme
        for entry in info["CFBundleURLTypes"]
        for scheme in entry["CFBundleURLSchemes"]
    ]
    document = plistlib.loads((WORKFLOW / "document.wflow").read_bytes())
    command = document["actions"][0]["action"]["ActionParameters"]["COMMAND_STRING"]

    assert "transcribe" in schemes
    assert 'open -g -a "$APP" "$file"' in command
    assert "Transcribe.app" in command
