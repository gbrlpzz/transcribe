import AppKit

let app = NSApplication.shared
// App startup runs on the main thread; the delegate is main-actor isolated.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
// Menu-bar utility app: no Dock icon, no main menu requirement.
app.setActivationPolicy(.accessory)
app.run()
