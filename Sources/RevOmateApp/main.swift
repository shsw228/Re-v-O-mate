import AppKit

// AppKit entry point. Construction of the @MainActor AppDelegate (whose
// `model = AppModel()` default value is MainActor-isolated) is performed inside
// `MainActor.assumeIsolated` so it compiles regardless of whether top-level code
// is treated as MainActor-isolated or nonisolated by the toolchain — top-level
// runs on the main thread at launch, so the assumption always holds at runtime.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
