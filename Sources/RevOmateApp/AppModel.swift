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

    enum Section: Hashable, CaseIterable { case config, macros }
    var section: Section = .config

    var status: Status = .idle
    var version: String?
    var log: [String] = []
    var isBusy = false
    var progress: Double?          // 0..1 during long reads

    var statusText: String {
        switch status {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Rev-O-mate" + (version.map { " · FW \($0)" } ?? "")
        case .error(let m): return "Error: \(m)"
        }
    }

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
    var ledUseCustom = true
    var ledPreset = 0   // 0..8

    /// Editable action supporting None / Keyboard / mouse move+scroll / no-payload types.
    struct ActionDraft {
        var typeRaw: UInt8 = 0
        var ctrl = false, shift = false, alt = false, cmd = false
        var key: UInt8 = 0
        var sense: UInt8 = 100
        var moveX = 0, moveY = 0, wheel = 0

        var modifiers: KeyModifiers {
            var m: KeyModifiers = []
            if ctrl { m.insert(.leftCtrl) }; if shift { m.insert(.leftShift) }
            if alt { m.insert(.leftAlt) }; if cmd { m.insert(.leftGUI) }
            return m
        }
        var isKeyboard: Bool { typeRaw == 9 }
        var isMouseMove: Bool { typeRaw == 7 }
        var isMouseScroll: Bool { typeRaw == 8 }

        var action: ActionRecord {
            switch typeRaw {
            case 0: return .none
            case 9: return .keyboard(modifiers, [key], sense: sense)
            case 7: return ActionRecord(type: SetType(7),
                                        payload: [0, UInt8(bitPattern: Int8(clamping: moveX)),
                                                  UInt8(bitPattern: Int8(clamping: moveY)), 0, 0, 0], sense: sense)
            case 8: return ActionRecord(type: SetType(8),
                                        payload: [0, 0, 0, UInt8(bitPattern: Int8(clamping: wheel)), 0, 0], sense: sense)
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
            moveX = Int(Int8(bitPattern: a.payload[1]))
            moveY = Int(Int8(bitPattern: a.payload[2]))
            wheel = Int(Int8(bitPattern: a.payload[3]))
        }
    }

    static let editableTypes: [UInt8] = Array(0...44)

    var cwDraft = ActionDraft()
    var ccwDraft = ActionDraft()

    var selectedButton = 0 { didSet { loadButtonEdit() } }
    var buttonDraft = ActionDraft()
    var buttonScriptNo = 0
    var buttonSpFuncNo = 0

    // Macro (script) editing
    var selectedScriptNumber: Int?
    var scriptDraft: [ScriptCommand] = []
    var scriptMode: ScriptInfo.Mode = .oneShot
    var scriptName = ""

    /// All device I/O runs here — a dedicated serial queue, NOT the Swift concurrency
    /// cooperative pool (blocking IOKit calls would starve it).
    private let io = DispatchQueue(label: "com.revomate.app.io")
    private var device: RevOmateDevice?

    var isConnected: Bool { if case .connected = status { return true } else { return false } }

    static let presetRGB: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 0), (100, 100, 100), (100, 0, 0), (100, 45, 0), (100, 100, 0),
        (0, 100, 100), (0, 100, 0), (0, 0, 100), (100, 0, 100),
    ]
    static let presetNames = ["Off", "White", "Red", "Orange", "Yellow", "Turquoise", "Green", "Blue", "Purple"]

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
        progress = 0
        append("Opening device and reading configuration…")
        io.async { [weak self] in
            do {
                let dev = try RevOmateDevice()
                let v = try dev.version()
                // Phase 1: config only (fast) -> connected.
                var lastPct = -1
                let img = try dev.readConfig { done, total in
                    let pct = done * 100 / max(total, 1)
                    if pct != lastPct && pct % 5 == 0 {
                        lastPct = pct
                        DispatchQueue.main.async { self?.progress = Double(pct) / 100 }
                    }
                }
                let cfg = ConfigImage(img)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.device = dev; self.version = v; self.image = img; self.config = cfg
                    self.progress = nil; self.status = .connected
                    self.loadLEDEdit(); self.loadFuncEdit(); self.loadButtonEdit()
                    self.append("Connected — FW \(v). Loading macros…")
                }
                // Phase 2: scripts (background) -> Macros tab fills in.
                let img2 = try dev.readScripts(into: img)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.image = img2
                    self.config = ConfigImage(img2)
                    self.selectScript(self.scripts.first?.number)
                    self.append("Macros loaded (\(self.scripts.count)).")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.progress = nil; self?.status = .error("\(error)"); self?.append("✗ \(error)")
                }
            }
        }
    }

    private func loadLEDEdit() {
        guard let cfg = config, selectedMode < cfg.modes.count else { return }
        let m = cfg.modes[selectedMode]
        ledR = Double(m.ledRGB.0); ledG = Double(m.ledRGB.1); ledB = Double(m.ledRGB.2)
        ledBrightness = Int(m.ledBrightness)
        ledUseCustom = m.ledColorFlag == 1
        ledPreset = Int(min(m.ledColorNo, 8))
    }

    private func loadFuncEdit() {
        guard let cfg = config else { return }
        let idx = selectedMode * FlashMap.functionsPerMode + selectedFunc
        guard idx < cfg.functions.count else { return }
        cwDraft = ActionDraft(cfg.functions[idx].cw)
        ccwDraft = ActionDraft(cfg.functions[idx].ccw)
    }

    private func loadButtonEdit() {
        guard let cfg = config else { return }
        let idx = selectedMode * FlashMap.swCount + selectedButton
        guard idx < cfg.swFunctions.count, selectedMode < cfg.modes.count else { return }
        buttonDraft = ActionDraft(cfg.swFunctions[idx].action)
        buttonScriptNo = Int(cfg.modes[selectedMode].swExeScriptNo[selectedButton])
        buttonSpFuncNo = Int(cfg.modes[selectedMode].swSpFuncNo[selectedButton])
    }

    // MARK: Shared write-back (persist changed sectors + reload)

    private func writeBack(_ newImage: [UInt8], _ label: String, reconnectHint: Bool = false) {
        guard let dev = device, let baseline = image, !isBusy else { return }
        isBusy = true
        append(label)
        io.async { [weak self] in
            do {
                let restored = try dev.restoreImage(newImage, baseline: baseline)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.image = newImage
                    self.config = ConfigImage(newImage)
                    self.append("✓ Saved — \(restored.count) sector(s)." + (reconnectHint ? " Reconnect to apply." : ""))
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async { self?.append("✗ Save failed: \(error)"); self?.isBusy = false }
            }
        }
    }

    // MARK: Live LED preview (0x63) — coalesced on the io queue

    private var ledLatest: (UInt8, UInt8, UInt8, UInt8)?
    private var ledScheduled = false

    func previewLED() {
        let rgb: (UInt8, UInt8, UInt8) = ledUseCustom
            ? (UInt8(ledR), UInt8(ledG), UInt8(ledB))
            : Self.presetRGB[min(ledPreset, 8)]
        ledLatest = (rgb.0, rgb.1, rgb.2, UInt8(ledBrightness))
        guard !ledScheduled, let dev = device else { return }
        ledScheduled = true
        io.async { [weak self] in
            while true {
                let next: (UInt8, UInt8, UInt8, UInt8)? = DispatchQueue.main.sync {
                    let n = self?.ledLatest
                    self?.ledLatest = nil
                    if n == nil { self?.ledScheduled = false }
                    return n
                }
                guard let d = next else { break }
                try? dev.setLEDLive(r: d.0, g: d.1, b: d.2, brightness: d.3)
            }
        }
    }

    // MARK: Saves

    func saveLED() {
        guard let img = image else { return }
        var editor = ConfigEditor(img)
        if ledUseCustom {
            editor.setModeLED(mode: selectedMode, colorNo: 0, useCustomRGB: true,
                              rgb: (UInt8(ledR), UInt8(ledG), UInt8(ledB)), brightness: UInt8(ledBrightness))
        } else {
            editor.setModeLEDPreset(mode: selectedMode, colorNo: UInt8(ledPreset), brightness: UInt8(ledBrightness))
        }
        writeBack(editor.image, "Saving Mode \(selectedMode) LED…")
    }

    func saveDialFunction() {
        guard let img = image else { return }
        var editor = ConfigEditor(img)
        editor.setDialAction(mode: selectedMode, func: selectedFunc, cw: cwDraft.action, ccw: ccwDraft.action)
        writeBack(editor.image, "Saving Mode \(selectedMode) dial function \(selectedFunc)…", reconnectHint: true)
    }

    func saveButton() {
        guard let img = image else { return }
        var editor = ConfigEditor(img)
        editor.setButtonAction(mode: selectedMode, sw: selectedButton, buttonDraft.action)
        editor.setButtonScript(mode: selectedMode, sw: selectedButton, scriptNo: UInt8(buttonScriptNo))
        editor.setButtonSpecialFunc(mode: selectedMode, sw: selectedButton, funcNo: UInt8(buttonSpFuncNo))
        writeBack(editor.image, "Saving Mode \(selectedMode) SW\(selectedButton + 1)…", reconnectHint: true)
    }

    // MARK: Macro (script) editing

    var scripts: [ConfigImage.ScriptEntry] { config?.scripts ?? [] }
    var scriptByteCount: Int { ScriptEncoder.encode(scriptDraft).count }

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
        // Reset parameters when the command type changes (don't reinterpret old bytes,
        // e.g. a wait's ms high-byte becoming a keycode).
        scriptDraft[index] = ScriptCommand(opcode)
    }
    func setCommandByte(_ index: Int, _ byteIndex: Int, _ value: UInt8) {
        guard scriptDraft.indices.contains(index), scriptDraft[index].data.indices.contains(byteIndex) else { return }
        scriptDraft[index].data[byteIndex] = value
    }
    func setWaitMs(_ index: Int, _ ms: UInt16) {
        guard scriptDraft.indices.contains(index) else { return }
        scriptDraft[index] = .wait(ms: ms)
    }

    func saveScript() {
        guard let img = image, let n = selectedScriptNumber else { return }
        var editor = ConfigEditor(img)
        guard editor.setScript(number: n, commands: scriptDraft, mode: scriptMode, name: scriptName) else {
            append("✗ Script #\(n) has no allocated data region (can't edit in place)."); return
        }
        writeBack(editor.image, "Saving script #\(n) (\(scriptByteCount) B)…", reconnectHint: true)
    }

    // MARK: Backup

    /// Full 2 MiB backup — reads the entire flash fresh (the connect read is sparse).
    func backup() {
        guard let dev = device, !isBusy else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "revomate-backup.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isBusy = true
        progress = 0
        append("Reading full 2 MiB flash for backup…")
        io.async { [weak self] in
            do {
                var lastPct = -1
                let full = try dev.dumpAll { done, total in
                    let pct = done * 100 / total
                    if pct != lastPct && pct % 5 == 0 {
                        lastPct = pct
                        DispatchQueue.main.async { self?.progress = Double(pct) / 100 }
                    }
                }
                try Data(full).write(to: url)
                DispatchQueue.main.async {
                    self?.progress = nil; self?.isBusy = false
                    self?.append("✓ Backup saved: \(url.lastPathComponent)")
                }
            } catch {
                DispatchQueue.main.async { self?.progress = nil; self?.isBusy = false; self?.append("✗ Backup failed: \(error)") }
            }
        }
    }
}
