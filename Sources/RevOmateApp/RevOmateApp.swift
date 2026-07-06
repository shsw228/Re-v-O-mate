import AppKit
import SwiftUI

/// Entry point. Uses `@main` + a `@MainActor` `main()` (no top-level code) so it
/// compiles in both script mode (`swift build`) and library mode (`-parse-as-library`,
/// which Xcode app targets use), and constructs the @MainActor AppDelegate on the MainActor.
@main
enum RevOmateMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

private extension NSToolbarItem.Identifier {
    static let connect = NSToolbarItem.Identifier("connect")
    static let backup = NSToolbarItem.Identifier("backup")
    static let status = NSToolbarItem.Identifier("status")
}

/// Hosts a SwiftUI view pinned to fill its container (so it takes the split pane's width).
@MainActor
final class HostVC<Content: View>: NSViewController {
    private let root: Content
    init(_ root: Content) { self.root = root; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    let model = AppModel()
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)

        if ProcessInfo.processInfo.environment["REVOMATE_SMOKE"] != nil { startSmoke() }
        if ProcessInfo.processInfo.environment["REVOMATE_HOLD"] != nil { model.connect() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Window / split view / toolbar

    private func buildWindow() {
        let split = NSSplitViewController()

        let sidebar = NSSplitViewItem(sidebarWithViewController: HostVC(SidebarView(model: model)))
        sidebar.minimumThickness = 170
        sidebar.maximumThickness = 240
        split.addSplitViewItem(sidebar)

        let content = NSSplitViewItem(viewController: HostVC(DetailView(model: model)))
        content.minimumThickness = 460
        split.addSplitViewItem(content)

        window = NSWindow(contentViewController: split)
        window.setContentSize(NSSize(width: 820, height: 620))
        window.title = "Re-v-O-mate"
        window.styleMask.insert(.fullSizeContentView)

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Re-v-O-mate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    // MARK: NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .connect:
            return button(id, label: "Connect", symbol: "cable.connector", action: #selector(connect))
        case .backup:
            return button(id, label: "Backup", symbol: "square.and.arrow.down", action: #selector(backup))
        case .status:
            let item = NSToolbarItem(itemIdentifier: .status)
            let host = NSHostingView(rootView: StatusView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 260, height: 28)
            item.view = host
            item.visibilityPriority = .high
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.connect, .backup, .flexibleSpace, .status]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.connect, .backup, .flexibleSpace, .status]
    }

    private func button(_ id: NSToolbarItem.Identifier, label: String, symbol: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    @objc private func connect() { model.connect() }
    @objc private func backup() { model.backup() }

    // MARK: Smoke test (REVOMATE_SMOKE=1)

    private var smokeTimer: Timer?
    private var smokeSeen = 0
    private func startSmoke() {
        model.connect()
        smokeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                while self.smokeSeen < self.model.log.count {
                    let line = self.model.log[self.smokeSeen]; self.smokeSeen += 1
                    FileHandle.standardError.write(("SMOKE: " + line + "\n").data(using: .utf8)!)
                    if line.contains("Macros loaded") { exit(0) }
                    if line.hasPrefix("✗") { exit(3) }
                }
            }
        }
    }
}
