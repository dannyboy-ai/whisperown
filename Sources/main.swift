import Cocoa

// Menubar-only app: .accessory means no Dock icon and no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
