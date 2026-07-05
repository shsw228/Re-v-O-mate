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
