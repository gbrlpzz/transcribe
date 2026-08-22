import AppKit
import TranscribeCLI

// Single-binary dispatch (R49): basename(argv[0]) == "transcribe" runs the CLI
// and exits; anything else boots the menu-bar app. No second binary ships.
if CommandLine.arguments.first.map({ ($0 as NSString).lastPathComponent }) == "transcribe" {
    TranscribeCLI.entry()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar utility app: no Dock icon, no main menu requirement.
app.setActivationPolicy(.accessory)
app.run()
