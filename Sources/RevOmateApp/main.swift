import AppKit

// AppKit entry point (the UI shell is AppKit; screen content is SwiftUI via NSHostingController).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
