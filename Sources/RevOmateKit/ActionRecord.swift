import Foundation

/// The `set type` of an 8-byte action record (byte 0). Values 0..44 from `app.h`.
public struct SetType: Equatable, Sendable, CustomStringConvertible {
    public let raw: UInt8
    public init(_ raw: UInt8) { self.raw = raw }

    public enum Category: Sendable {
        case none, mouse, keyboard, multimedia, joypad, specialNumber, encoderScript, unknown
    }

    public var category: Category {
        switch raw {
        case 0: return .none
        case 1...8: return .mouse
        case 9: return .keyboard
        case 10...20: return .multimedia
        case 21...39: return .joypad
        case 40...41: return .specialNumber
        case 42...44: return .encoderScript
        default: return .unknown
        }
    }

    public var description: String {
        switch raw {
        case 0: return "None"
        case 1: return "Mouse L"
        case 2: return "Mouse R"
        case 3: return "Mouse Wheel click"
        case 4: return "Mouse B4"
        case 5: return "Mouse B5"
        case 6: return "Mouse double-click"
        case 7: return "Mouse move"
        case 8: return "Mouse scroll"
        case 9: return "Keyboard"
        case 10: return "Media Play"
        case 11: return "Media Pause"
        case 12: return "Media Stop"
        case 13: return "Media Record"
        case 14: return "Media FF"
        case 15: return "Media Rewind"
        case 16: return "Media Next"
        case 17: return "Media Prev"
        case 18: return "Media Mute"
        case 19: return "Media Vol+"
        case 20: return "Media Vol-"
        case 21: return "Joypad axis X/Y"
        case 22: return "Joypad axis Z/Rz"
        case 23...35: return "Joypad button \(raw - 22)"
        case 36: return "Joypad HAT N"
        case 37: return "Joypad HAT S"
        case 38: return "Joypad HAT W"
        case 39: return "Joypad HAT E"
        case 40: return "Special number +"
        case 41: return "Special number -"
        case 42...44: return "Encoder script \(raw - 41)"
        default: return "Unknown(0x\(String(raw, radix: 16)))"
        }
    }
}

/// USB HID keyboard modifier bits (byte 1 for keyboard actions).
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let leftCtrl = KeyModifiers(rawValue: 0x01)
    public static let leftShift = KeyModifiers(rawValue: 0x02)
    public static let leftAlt = KeyModifiers(rawValue: 0x04)
    public static let leftGUI = KeyModifiers(rawValue: 0x08)
    public static let rightCtrl = KeyModifiers(rawValue: 0x10)
    public static let rightShift = KeyModifiers(rawValue: 0x20)
    public static let rightAlt = KeyModifiers(rawValue: 0x40)
    public static let rightGUI = KeyModifiers(rawValue: 0x80)

    public var labels: [String] {
        var out: [String] = []
        if contains(.leftCtrl) || contains(.rightCtrl) { out.append("Ctrl") }
        if contains(.leftShift) || contains(.rightShift) { out.append("Shift") }
        if contains(.leftAlt) || contains(.rightAlt) { out.append("Alt") }
        if contains(.leftGUI) || contains(.rightGUI) { out.append("Cmd") }
        return out
    }
}

/// An 8-byte device-action record. Used by dial CW/CCW (function setting) and by
/// each SW/button. Layout: byte0 = set type; bytes 1..6 depend on the type;
/// byte7 = sensitivity (rotary encoder). See the protocol spec §4.3.
public struct ActionRecord: Sendable {
    public var type: SetType
    public var payload: [UInt8]  // bytes 1..6 (6 bytes)
    public var sense: UInt8  // byte 7

    public init(_ bytes: ArraySlice<UInt8>) {
        let b = Array(bytes)
        precondition(b.count >= 8)
        type = SetType(b[0])
        payload = Array(b[1...6])
        sense = b[7]
    }

    public init(type: SetType, payload: [UInt8], sense: UInt8) {
        self.type = type
        var p = payload
        while p.count < 6 { p.append(0) }
        self.payload = Array(p.prefix(6))
        self.sense = sense
    }

    /// The canonical 8-byte on-flash form: [type][payload×6][sense].
    public var encoded: [UInt8] { [type.raw] + payload + [sense] }

    public var isEmpty: Bool { type.raw == 0 }

    public static let none = ActionRecord(type: SetType(0), payload: [], sense: 100)

    /// Build a keyboard action (set type 9): modifiers + up to 3 keys.
    public static func keyboard(_ modifiers: KeyModifiers, _ keys: [UInt8], sense: UInt8 = 100) -> ActionRecord {
        var k = keys; while k.count < 3 { k.append(0) }
        return ActionRecord(type: SetType(9), payload: [modifiers.rawValue, k[0], k[1], k[2], 0, 0], sense: sense)
    }

    // Typed accessors for the keyboard payload.
    public var keyModifiers: KeyModifiers { KeyModifiers(rawValue: payload[0]) }
    public var keys: [UInt8] { Array(payload[1...3]) }

    /// Human-readable one-liner (best-effort; keycode names are a small subset).
    public func describe() -> String {
        switch type.category {
        case .none:
            return "—"
        case .keyboard:
            let mods = KeyModifiers(rawValue: payload[0]).labels
            let keys = payload[1...3].filter { $0 != 0 }.map { HIDKey.name($0) }
            return (mods + keys).joined(separator: "+")
        case .mouse:
            if type.raw == 7 {
                return "Mouse move (x=\(Int8(bitPattern: payload[1])), y=\(Int8(bitPattern: payload[2])))"
            }
            if type.raw == 8 { return "Mouse scroll (\(Int8(bitPattern: payload[3])))" }
            return type.description
        case .multimedia, .joypad, .specialNumber, .encoderScript, .unknown:
            return type.description
        }
    }
}

/// A named HID key for pickers.
public struct NamedKey: Identifiable, Sendable, Hashable {
    public let name: String
    public let usage: UInt8
    public var id: UInt8 { usage }
    public init(_ name: String, _ usage: UInt8) { self.name = name; self.usage = usage }
}

/// Minimal HID usage-id -> label map for common keys (extend as needed).
public enum HIDKey {
    /// A curated list for UI pickers (letters, digits, function keys, common punctuation, arrows).
    public static let common: [NamedKey] = {
        var out: [NamedKey] = [NamedKey("(none)", 0)]
        for c in 0x04...0x1D { out.append(NamedKey(name(UInt8(c)), UInt8(c))) }  // a..z
        for c in 0x1E...0x27 { out.append(NamedKey(name(UInt8(c)), UInt8(c))) }  // 1..0
        for c in 0x3A...0x45 { out.append(NamedKey(name(UInt8(c)), UInt8(c))) }  // F1..F12
        for c: UInt8 in [
            0x28, 0x29, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x36, 0x37, 0x38,
            0x4F, 0x50, 0x51, 0x52,
        ] {
            out.append(NamedKey(name(c), c))
        }
        return out
    }()

    public static func name(_ code: UInt8) -> String {
        switch code {
        case 0x04...0x1D: return String(UnicodeScalar(0x61 + (code - 0x04)))  // a..z
        case 0x1E...0x26: return String(UnicodeScalar(0x31 + (code - 0x1E)))  // 1..9
        case 0x27: return "0"
        case 0x28: return "Return"
        case 0x29: return "Esc"
        case 0x2A: return "Backspace"
        case 0x2B: return "Tab"
        case 0x2C: return "Space"
        case 0x2D: return "-"
        case 0x2E: return "="
        case 0x2F: return "["
        case 0x30: return "]"
        case 0x31: return "\\"
        case 0x33: return ";"
        case 0x34: return "'"
        case 0x36: return ","
        case 0x37: return "."
        case 0x38: return "/"
        case 0x3A...0x45: return "F\(code - 0x39)"  // F1..F12
        case 0x4F: return "Right"
        case 0x50: return "Left"
        case 0x51: return "Down"
        case 0x52: return "Up"
        default: return "0x\(String(code, radix: 16))"
        }
    }
}
