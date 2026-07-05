import Foundation
import AppKit
import RevOmateKit

@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle, connecting, connected, error(String)
    }

    var status: Status = .idle
    var version: String?
    var scriptCount: Int?
    var log: [String] = []

    // MainActor-isolated handle; work runs in detached tasks on the captured local.
    private var device: RevOmateDevice?

    var isConnected: Bool { if case .connected = status { return true } else { return false } }

    private func append(_ s: String) { log.append(s) }

    func connect() {
        guard status != .connecting else { return }
        status = .connecting
        append("Opening vendor interface (VID 0x22EA / UsagePage 0xFF00)…")
        Task {
            do {
                let dev = try await Task.detached { try RevOmateDevice() }.value
                let v = try await Task.detached { try dev.version() }.value
                let sh = try await Task.detached { try dev.scriptHeader() }.value
                self.device = dev
                self.version = v
                self.scriptCount = Int(sh.recordCount)
                self.status = .connected
                self.append("Connected — FW \(v), scripts=\(sh.recordCount).")
            } catch {
                self.status = .error("\(error)")
                self.append("✗ \(error)")
            }
        }
    }

    func dumpToFile() {
        guard let dev = device else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "revomate-backup.bin"
        panel.title = "Save Rev-O-mate flash backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        append("Dumping 2 MiB flash → \(url.lastPathComponent)…")
        Task {
            do {
                let data = try await Task.detached { try dev.dumpAll() }.value
                try Data(data).write(to: url)
                self.append("✓ Wrote \(data.count) bytes.")
            } catch {
                self.append("✗ Dump failed: \(error)")
            }
        }
    }
}
