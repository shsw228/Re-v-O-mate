import Foundation

/// Rev-O-mate macro/script bytecode opcodes (from firmware `l_script.h`).
///
/// A script is a contiguous stream of `[opcode][data...]` commands where the
/// data length is fixed per opcode. For 2-byte data the FIRST byte is the high
/// byte (big-endian within the command, e.g. WAIT ms).
public enum ScriptOpcode: UInt8, CaseIterable, Sendable {
    case wait = 0x70  // 2: delay ms
    case keyPress = 0x41  // 1: HID keycode
    case keyRelease = 0x40  // 1
    case multiPress = 0x43  // 1: modifier / multimedia
    case multiRelease = 0x42  // 1
    case mousePressL = 0x29  // 0
    case mouseReleaseL = 0x21  // 0
    case mousePressR = 0x2A  // 0
    case mouseReleaseR = 0x22  // 0
    case mousePressW = 0x2C  // 0
    case mouseReleaseW = 0x24  // 0
    case mousePressB4 = 0x2D  // 0
    case mouseReleaseB4 = 0x25  // 0
    case mousePressB5 = 0x2E  // 0
    case mouseReleaseB5 = 0x26  // 0
    case mouseScrollUp = 0x31  // 1
    case mouseScrollDown = 0x32  // 1
    case mouseMove = 0x33  // 2: X(hi), Y(lo) relative
    case joyBtnPress = 0x69  // 1: button id 0..12
    case joyBtnRelease = 0x61  // 1
    case joyHatPress = 0x6A  // 1: dir 0..7
    case joyHatRelease = 0x62  // 1
    case joyLLever = 0x6B  // 2
    case joyLLeverCenter = 0x63  // 0
    case joyRLever = 0x6C  // 2
    case joyRLeverCenter = 0x64  // 0

    /// Number of data bytes that follow this opcode.
    public var dataLength: Int {
        switch self {
        case .wait, .mouseMove, .joyLLever, .joyRLever:
            return 2
        case .keyPress, .keyRelease, .multiPress, .multiRelease,
            .mouseScrollUp, .mouseScrollDown,
            .joyBtnPress, .joyBtnRelease, .joyHatPress, .joyHatRelease:
            return 1
        default:
            return 0
        }
    }
}

/// One decoded script command.
public struct ScriptCommand: Sendable, Identifiable {
    public let id = UUID()
    public var opcode: ScriptOpcode
    public var data: [UInt8]

    public init(_ opcode: ScriptOpcode, _ data: [UInt8] = []) {
        self.opcode = opcode
        var d = data
        while d.count < opcode.dataLength { d.append(0) }
        self.data = Array(d.prefix(opcode.dataLength))
    }

    /// On-flash bytes: [opcode][data...]. For 2-byte data the first byte is the high byte.
    public var encoded: [UInt8] { [opcode.rawValue] + data }

    // Convenience builders
    public static func wait(ms: UInt16) -> ScriptCommand {
        ScriptCommand(.wait, [UInt8(ms >> 8), UInt8(ms & 0xFF)])
    }
    public static func keyPress(_ code: UInt8) -> ScriptCommand { ScriptCommand(.keyPress, [code]) }
    public static func keyRelease(_ code: UInt8) -> ScriptCommand { ScriptCommand(.keyRelease, [code]) }

    /// Human-readable one-liner.
    public var describe: String {
        switch opcode {
        case .wait: return "wait \(UInt16(data[0]) << 8 | UInt16(data[1]))ms"
        case .keyPress: return "press \(HIDKey.name(data[0]))"
        case .keyRelease: return "release \(HIDKey.name(data[0]))"
        case .mouseScrollUp: return "scroll up \(data[0])"
        case .mouseScrollDown: return "scroll down \(data[0])"
        case .mouseMove: return "mouse move \(Int8(bitPattern: data[0])),\(Int8(bitPattern: data[1]))"
        default: return "\(opcode)" + (data.isEmpty ? "" : " (\(data.hexString))")
        }
    }
}

public enum ScriptEncoder {
    /// Encode a command list into the on-flash byte stream.
    public static func encode(_ commands: [ScriptCommand]) -> [UInt8] {
        commands.flatMap { $0.encoded }
    }
}

public enum ScriptDecoder {
    /// Decode a raw script byte stream into commands.
    /// Unknown opcodes stop decoding (returns what parsed so far + remainder count).
    public static func decode(_ bytes: [UInt8]) -> (commands: [ScriptCommand], undecodedBytes: Int) {
        var out: [ScriptCommand] = []
        var i = 0
        while i < bytes.count {
            guard let op = ScriptOpcode(rawValue: bytes[i]) else { return (out, bytes.count - i) }
            let n = op.dataLength
            guard i + 1 + n <= bytes.count else { return (out, bytes.count - i) }
            out.append(ScriptCommand(op, Array(bytes[(i + 1)..<(i + 1 + n)])))
            i += 1 + n
        }
        return (out, 0)
    }
}
