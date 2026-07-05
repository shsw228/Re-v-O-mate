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

    var selectedMode = 0 { didSet { loadLEDEdit(); loadFuncEdit(); loadButtonEdit() } }
    var selectedFunc = 0 { didSet { loadFuncEdit() } }

    // Editable LED state for the selected mode (RGB as 0..100 duty).
    var ledR = 0.0
    var ledG = 0.0
    var ledB = 0.0
    var ledBrightness = 1

    /// Editable action supporting None / Keyboard / no-payload types (mouse buttons, media).
    struct ActionDraft {
        var typeRaw: UInt8 = 0
        var ctrl = false, shift = false, alt = false, cmd = false
        var key: UInt8 = 0
        var sense: UInt8 = 100

        var modifiers: KeyModifiers {
            var m: KeyModifiers = []
            if ctrl { m.insert(.leftCtrl) }; if shift { m.insert(.leftShift) }
            if alt { m.insert(.leftAlt) }; if cmd { m.insert(.leftGUI) }
            return m
        }
        var isKeyboard: Bool { typeRaw == 9 }
        var action: ActionRecord {
            switch typeRaw {
            case 0: return .none
            case 9: return .keyboard(modifiers, [key], sense: sense)
            default: return ActionRecord(type: SetType(typeRaw), payload: [], sense: sense)
            }
        }
        init() {}
        init(_ a: ActionRecord) {
            typeRaw = a.type.raw
            let m = a.keyModifiers
            ctrl = m.contains(.leftCtrl) || m.contains(.rightCtrl)
            shift = m.contains(.leftShift) || m.contains(.rightShift)
            alt = m.contains(.leftAlt) || m.contains(.rightAlt)
            cmd = m.contains(.leftGUI) || m.contains(.rightGUI)
            key = a.keys.first ?? 0
            sense = a.sense == 0 ? 100 : a.sense
        }
    }

    /// SetType values offered in the editor (None / Keyboard / no-payload types).
    static let editableTypes: [UInt8] = [0, 9, 1, 2, 3, 4, 5, 6, 10, 11, 12, 16, 17, 18, 19, 20]

    var cwDraft = ActionDraft()
    var ccwDraft = ActionDraft()

    // Buttons (direct SW action record)
    var selectedButton = 0 { didSet { loadButtonEdit() } }
    var buttonDraft = ActionDraft()

    // LED preset vs custom
    var ledUseCustom = true
    var ledPreset = 0   // 0..8

    // Macro (script) editing
    var selectedScriptNumber: Int?
    var scriptDraft: [ScriptCommand] = []
    var scriptMode: ScriptInfo.Mode = .oneShot
    var scriptName = ""

    private var device: RevOmateDevice?

    var isConnected: Bool { if case .connected = status { return true } else { return false } }
    var ledSwatch: Color {
        let rgb: (Double, Double, Double)
        if ledUseCustom { rgb = (ledR, ledG, ledB) }
        else { let p = Self.presetRGB[min(ledPreset, 8)]; rgb = (Double(p.0), Double(p.1), Double(p.2)) }
        return Color(red: rgb.0 / 100, green: rgb.1 / 100, blue: rgb.2 / 100)
    }

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
                self.loadFuncEdit()
                self.loadButtonEdit()
                self.selectScript(self.scripts.first?.number)
                self.append("Connected — FW \(v).")
            } catch {
                self.status = .error("\(error)")
                self.append("✗ \(error)")
            }
        }
    }

    /// Approximate duty RGB for each of the 9 preset colors (for live preview only;
    /// persistence stores the preset index so the firmware renders the exact color).
    static let presetRGB: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 0), (100, 100, 100), (100, 0, 0), (100, 45, 0), (100, 100, 0),
        (0, 100, 100), (0, 100, 0), (0, 0, 100), (100, 0, 100),
    ]
    static let presetNames = ["Off", "White", "Red", "Orange", "Yellow", "Turquoise", "Green", "Blue", "Purple"]

    private func loadLEDEdit() {
        guard let cfg = config, selectedMode < cfg.modes.count else { return }
        let m = cfg.modes[selectedMode]
        ledR = Double(m.ledRGB.0); ledG = Double(m.ledRGB.1); ledB = Double(m.ledRGB.2)
        ledBrightness = Int(m.ledBrightness)
        ledUseCustom = m.ledColorFlag == 1
        ledPreset = Int(min(m.ledColorNo, 8))
    }

    private func loadButtonEdit() {
        guard let cfg = config else { return }
        let idx = selectedMode * FlashMap.swCount + selectedButton
        guard idx < cfg.swFunctions.count else { return }
        buttonDraft = ActionDraft(cfg.swFunctions[idx].action)
    }

    private func loadFuncEdit() {
        guard let cfg = config else { return }
        let idx = selectedMode * FlashMap.functionsPerMode + selectedFunc
        guard idx < cfg.functions.count else { return }
        cwDraft = ActionDraft(cfg.functions[idx].cw)
        ccwDraft = ActionDraft(cfg.functions[idx].ccw)
    }

    var selectedFuncName: String {
        guard let cfg = config else { return "" }
        let idx = selectedMode * FlashMap.functionsPerMode + selectedFunc
        return idx < cfg.functionNames.count ? cfg.functionNames[idx] : ""
    }

    /// Persist the edited CW/CCW keyboard actions for the selected dial function.
    /// NOTE: dial/button changes take effect after a mode switch or reconnect
    /// (firmware runs off a RAM mirror; only LED has a live command).
    func saveDialFunction() {
        guard let dev = device, let img = image, !isBusy else { return }
        var editor = ConfigEditor(img)
        editor.setDialAction(mode: selectedMode, func: selectedFunc,
                             cw: cwDraft.action, ccw: ccwDraft.action)
        let newImage = editor.image
        isBusy = true
        append("Saving Mode \(selectedMode) dial function \(selectedFunc)…")
        Task {
            do {
                let restored = try await Task.detached { try dev.restoreImage(newImage, baseline: img) }.value
                self.image = newImage
                self.config = ConfigImage(newImage)
                self.append("✓ Saved — \(restored.count) sector(s). Takes effect after mode switch / reconnect.")
            } catch {
                self.append("✗ Save failed: \(error)")
            }
            self.isBusy = false
        }
    }

    // MARK: Live LED preview (0x63) — coalesced

    private var ledSending = false
    private var ledDesired: (UInt8, UInt8, UInt8, UInt8)?

    func previewLED() {
        let rgb: (UInt8, UInt8, UInt8) = ledUseCustom
            ? (UInt8(ledR), UInt8(ledG), UInt8(ledB))
            : Self.presetRGB[min(ledPreset, 8)]
        ledDesired = (rgb.0, rgb.1, rgb.2, UInt8(ledBrightness))
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
        if ledUseCustom {
            editor.setModeLED(mode: selectedMode, colorNo: 0, useCustomRGB: true,
                              rgb: (UInt8(ledR), UInt8(ledG), UInt8(ledB)), brightness: UInt8(ledBrightness))
        } else {
            editor.setModeLEDPreset(mode: selectedMode, colorNo: UInt8(ledPreset), brightness: UInt8(ledBrightness))
        }
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

    /// Persist the edited direct action for the selected button (SW function record).
    func saveButton() {
        guard let dev = device, let img = image, !isBusy else { return }
        var editor = ConfigEditor(img)
        editor.setButtonAction(mode: selectedMode, sw: selectedButton, buttonDraft.action)
        let newImage = editor.image
        isBusy = true
        append("Saving Mode \(selectedMode) SW\(selectedButton + 1) action…")
        Task {
            do {
                let restored = try await Task.detached { try dev.restoreImage(newImage, baseline: img) }.value
                self.image = newImage
                self.config = ConfigImage(newImage)
                self.append("✓ Saved — \(restored.count) sector(s). Takes effect after mode switch / reconnect.")
            } catch {
                self.append("✗ Save failed: \(error)")
            }
            self.isBusy = false
        }
    }

    // MARK: Macro (script) editing

    var scripts: [ConfigImage.ScriptEntry] { config?.scripts ?? [] }

    func selectScript(_ number: Int?) {
        selectedScriptNumber = number
        guard let n = number, let e = scripts.first(where: { $0.number == n }) else {
            scriptDraft = []; scriptName = ""; scriptMode = .oneShot; return
        }
        scriptDraft = e.commands
        scriptName = e.info.name
        scriptMode = e.info.mode ?? .oneShot
    }

    func addCommand(_ opcode: ScriptOpcode) { scriptDraft.append(ScriptCommand(opcode)) }
    func deleteCommand(at offsets: IndexSet) { scriptDraft.remove(atOffsets: offsets) }
    func moveCommand(from: IndexSet, to: Int) { scriptDraft.move(fromOffsets: from, toOffset: to) }

    func setOpcode(_ index: Int, _ opcode: ScriptOpcode) {
        guard scriptDraft.indices.contains(index) else { return }
        scriptDraft[index] = ScriptCommand(opcode, scriptDraft[index].data)
    }
    func setCommandByte(_ index: Int, _ byteIndex: Int, _ value: UInt8) {
        guard scriptDraft.indices.contains(index), scriptDraft[index].data.indices.contains(byteIndex) else { return }
        scriptDraft[index].data[byteIndex] = value
    }
    func setWaitMs(_ index: Int, _ ms: UInt16) {
        guard scriptDraft.indices.contains(index) else { return }
        scriptDraft[index] = .wait(ms: ms)
    }

    var scriptByteCount: Int { ScriptEncoder.encode(scriptDraft).count }

    func saveScript() {
        guard let dev = device, let img = image, !isBusy, let n = selectedScriptNumber else { return }
        var editor = ConfigEditor(img)
        let ok = editor.setScript(number: n, commands: scriptDraft, mode: scriptMode, name: scriptName)
        guard ok else { append("✗ Script #\(n) has no allocated data region (can't edit in place)."); return }
        let newImage = editor.image
        isBusy = true
        append("Saving script #\(n) (\(scriptDraft.count) cmd, \(scriptByteCount) B)…")
        Task {
            do {
                let restored = try await Task.detached { try dev.restoreImage(newImage, baseline: img) }.value
                self.image = newImage
                self.config = ConfigImage(newImage)
                self.append("✓ Saved script #\(n) — \(restored.count) sector(s). Reconnect the device to run the new macro.")
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
