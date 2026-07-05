import Foundation
import SwiftUI
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
    var log: [String] = []
    var isBusy = false

    /// The last full image read from the device (baseline for diffed writes).
    private var image: [UInt8]?
    /// Parsed view of `image`.
    var config: ConfigImage?

    var selectedMode = 0 { didSet { loadLEDEdit() } }

    // Editable LED state for the selected mode (RGB as 0..100 duty).
    var ledR = 0.0
    var ledG = 0.0
    var ledB = 0.0
    var ledBrightness = 1

    private var device: RevOmateDevice?

    var isConnected: Bool { if case .connected = status { return true } else { return false } }
    var ledSwatch: Color { Color(red: ledR / 100, green: ledG / 100, blue: ledB / 100) }

    private func append(_ s: String) { log.append(s) }

    // MARK: Connect / load

    func connect() {
        guard status != .connecting else { return }
        status = .connecting
        append("Opening device and reading configuration…")
        Task {
            do {
                let dev = try await Task.detached { try RevOmateDevice() }.value
                let v = try await Task.detached { try dev.version() }.value
                let img = try await Task.detached { try dev.dumpAll() }.value
                self.device = dev
                self.version = v
                self.image = img
                self.config = ConfigImage(img)
                self.status = .connected
                self.loadLEDEdit()
                self.append("Connected — FW \(v).")
            } catch {
                self.status = .error("\(error)")
                self.append("✗ \(error)")
            }
        }
    }

    private func loadLEDEdit() {
        guard let cfg = config, selectedMode < cfg.modes.count else { return }
        let m = cfg.modes[selectedMode]
        ledR = Double(m.ledRGB.0); ledG = Double(m.ledRGB.1); ledB = Double(m.ledRGB.2)
        ledBrightness = Int(m.ledBrightness)
    }

    // MARK: Live LED preview (0x63) — coalesced

    private var ledSending = false
    private var ledDesired: (UInt8, UInt8, UInt8, UInt8)?

    func previewLED() {
        ledDesired = (UInt8(ledR), UInt8(ledG), UInt8(ledB), UInt8(ledBrightness))
        guard !ledSending, let dev = device else { return }
        ledSending = true
        Task {
            while let d = ledDesired {
                ledDesired = nil
                try? await Task.detached { try dev.setLEDLive(r: d.0, g: d.1, b: d.2, brightness: d.3) }.value
            }
            ledSending = false
        }
    }

    // MARK: Persist to flash (0x13/0x12), keeping the live value

    func saveLED() {
        guard let dev = device, let img = image, !isBusy else { return }
        var editor = ConfigEditor(img)
        editor.setModeLED(mode: selectedMode, colorNo: 0, useCustomRGB: true,
                          rgb: (UInt8(ledR), UInt8(ledG), UInt8(ledB)), brightness: UInt8(ledBrightness))
        let newImage = editor.image
        isBusy = true
        append("Saving Mode \(selectedMode) LED to flash…")
        Task {
            do {
                let restored = try await Task.detached { try dev.restoreImage(newImage, baseline: img) }.value
                self.image = newImage
                self.config = ConfigImage(newImage)
                self.append("✓ Saved — \(restored.count) sector(s) written.")
            } catch {
                self.append("✗ Save failed: \(error)")
            }
            self.isBusy = false
        }
    }

    func backup() {
        guard let img = image else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "revomate-backup.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(img).write(to: url); append("✓ Backup saved: \(url.lastPathComponent)") }
        catch { append("✗ Backup failed: \(error)") }
    }
}
