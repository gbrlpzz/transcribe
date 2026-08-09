import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar utility app: no Dock icon, no main menu requirement.
app.setActivationPolicy(.accessory)
app.run()
