import Foundation

/// Mutates a full 2 MiB flash image in place via typed setters that write to the
/// correct offsets (little-endian where needed). Pair with `RevOmateDevice.restoreImage`
/// to push only the changed sectors back to the device.
public struct ConfigEditor: Sendable {
    public private(set) var image: [UInt8]

    public init(_ image: [UInt8]) {
        precondition(image.count == FlashMap.totalSize, "editor needs a full 2 MiB image")
        self.image = image
    }

    private mutating func put(_ addr: UInt32, _ byte: UInt8) { image[Int(addr)] = byte }
    private mutating func put(_ addr: UInt32, _ bytes: [UInt8]) {
        for (i, b) in bytes.enumerated() { image[Int(addr) + i] = b }
    }

    private func swAddr(mode: Int, sw s: Int) -> UInt32 {
        FlashMap.swFunction + FlashMap.swStride * UInt32(mode * FlashMap.swCount + s)
    }

    private func baseModeAddr(_ mode: Int) -> UInt32 {
        FlashMap.baseModeInfo + FlashMap.baseModeStride * UInt32(mode)
    }
    private func functionAddr(mode: Int, func f: Int) -> UInt32 {
        FlashMap.functionSetting + FlashMap.functionStride * UInt32(mode * FlashMap.functionsPerMode + f)
    }

    // MARK: Per-mode LED

    public mutating func setModeLED(mode: Int, colorNo: UInt8, useCustomRGB: Bool,
                                    rgb: (UInt8, UInt8, UInt8), brightness: UInt8) {
        let b = baseModeAddr(mode)
        put(b + 23, colorNo)
        put(b + 24, useCustomRGB ? 1 : 0)
        put(b + 25, min(rgb.0, 100)); put(b + 26, min(rgb.1, 100)); put(b + 27, min(rgb.2, 100))
        put(b + 28, brightness)
    }

    /// Which of the 4 dial functions this mode uses by default (0..3).
    public mutating func setEncoderDefault(mode: Int, funcNo: UInt8) {
        put(baseModeAddr(mode) + 22, funcNo)
    }

    /// Use a preset color (0..8) for the mode LED instead of custom RGB.
    public mutating func setModeLEDPreset(mode: Int, colorNo: UInt8, brightness: UInt8) {
        let b = baseModeAddr(mode)
        put(b + 23, colorNo)
        put(b + 24, 0)          // color_flag = 0 => use preset
        put(b + 28, brightness)
    }

    // MARK: Action records (dial CW/CCW, buttons) — 8-byte records

    public mutating func setDialAction(mode: Int, func f: Int, cw: ActionRecord? = nil, ccw: ActionRecord? = nil) {
        let base = functionAddr(mode: mode, func: f)
        if let cw { put(base + 0, cw.encoded) }
        if let ccw { put(base + 8, ccw.encoded) }
    }

    public mutating func setButtonAction(mode: Int, sw s: Int, _ action: ActionRecord) {
        put(swAddr(mode: mode, sw: s), action.encoded)
    }

    /// Assign a script number (1-based; 0 = none) to a button, stored in base-mode info.
    public mutating func setButtonScript(mode: Int, sw s: Int, scriptNo: UInt8) {
        put(baseModeAddr(mode) + UInt32(s), scriptNo)          // sw_exe_script_no[s] @ +0..10
    }

    /// Assign a special-function number (0 = none) to a button.
    public mutating func setButtonSpecialFunc(mode: Int, sw s: Int, funcNo: UInt8) {
        put(baseModeAddr(mode) + 11 + UInt32(s), funcNo)       // sw_sp_func_no[s] @ +11..21
    }

    // MARK: Scripts (macros)

    private mutating func putU32LE(_ addr: UInt32, _ v: UInt32) {
        put(addr, [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    /// Overwrite an EXISTING script (1-based number) in place: rewrites its data at
    /// the address in its info slot, updates size/mode/name, and refreshes the header.
    /// Requires the slot to already have an allocated data address (size may be 0 but
    /// address must be non-zero). Assumes the new bytes fit in the script's sector.
    /// Returns false if the slot has no allocated data region.
    @discardableResult
    public mutating func setScript(number: Int, commands: [ScriptCommand],
                                   mode: ScriptInfo.Mode, name: String) -> Bool {
        let slot = FlashMap.scriptInfoAddress(number: number)
        let info = ScriptInfo(Array(image[Int(slot)..<Int(slot) + 0x110]))
        guard info.address != 0 else { return false }

        let newBytes = ScriptEncoder.encode(commands)
        let dataAddr = Int(info.address)
        let clearLen = Swift.max(Int(info.size), newBytes.count)
        for i in 0..<clearLen where dataAddr + i < image.count { image[dataAddr + i] = 0xFF }
        put(info.address, newBytes)

        // Update info slot: size, mode, name (UTF-16LE, byte-length prefix).
        putU32LE(slot + 4, UInt32(newBytes.count))
        put(slot + 8, mode.rawValue)
        let nameBytes = Array(name.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let clipped = Array(nameBytes.prefix(254))
        put(slot + 9, UInt8(clipped.count))
        if !clipped.isEmpty { put(slot + 10, clipped) }

        refreshScriptHeader()
        return true
    }

    /// Recompute Rec_Num (count of size>0 slots) and Total_Size in the script header.
    /// Check_SUM is left untouched (firmware does not appear to validate it).
    public mutating func refreshScriptHeader() {
        var count = 0
        var total: UInt32 = 0
        for n in 1...FlashMap.scriptMax {
            let a = Int(FlashMap.scriptInfoAddress(number: n))
            let size = u32le(Array(image[(a + 4)..<(a + 8)]), 0)
            if size > 0 { count += 1; total += size }
        }
        put(FlashMap.scriptHeader + 2, UInt8(min(count, 255)))
        putU32LE(FlashMap.scriptHeader + 4, total)
    }

    // MARK: Dial sensitivity (encoder), 1..100 per CW/CCW

    public mutating func setDialSensitivity(mode: Int, func f: Int, cw: UInt8, ccw: UInt8) {
        let b = functionAddr(mode: mode, func: f)
        put(b + 7, cw.clamped(1, 100))    // CW action record, byte 7
        put(b + 15, ccw.clamped(1, 100))  // CCW action record, byte 7
    }

    // MARK: Base header

    /// LED auto-off timeout in seconds (max 180).
    public mutating func setLedOffTime(seconds: UInt8) {
        put(FlashMap.baseHeader + 4, min(seconds, 180))
    }

    /// Encoder repeat behaviour: false = repeat (連打), true = hold (押しっぱなし).
    public mutating func setEncoderHold(_ hold: Bool) {
        put(FlashMap.baseHeader + 5, hold ? 1 : 0)
    }
}

private extension UInt8 {
    func clamped(_ lo: UInt8, _ hi: UInt8) -> UInt8 { Swift.min(Swift.max(self, lo), hi) }
}
