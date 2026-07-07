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

/// HID keyboard usage-id -> key name. The table is the JIS-layout name table from the
/// official app (`KeyCode.cs` `USB_KeyCode_Name`), so names match what the vendor tool shows.
public enum HIDKey {
    public static let names: [UInt8: String] = [
        0x04: "A", 0x05: "B", 0x06: "C", 0x07: "D", 0x08: "E", 0x09: "F", 0x0A: "G", 0x0B: "H",
        0x0C: "I", 0x0D: "J", 0x0E: "K", 0x0F: "L", 0x10: "M", 0x11: "N", 0x12: "O", 0x13: "P",
        0x14: "Q", 0x15: "R", 0x16: "S", 0x17: "T", 0x18: "U", 0x19: "V", 0x1A: "W", 0x1B: "X",
        0x1C: "Y", 0x1D: "Z",
        0x1E: "1", 0x1F: "2", 0x20: "3", 0x21: "4", 0x22: "5", 0x23: "6", 0x24: "7", 0x25: "8",
        0x26: "9", 0x27: "0",
        0x28: "Enter", 0x29: "ESC", 0x2A: "BS", 0x2B: "Tab", 0x2C: "Space",
        0x2D: "-", 0x2E: "^", 0x2F: "@", 0x30: "[", 0x32: "]", 0x33: ";", 0x34: ":",
        0x35: "ZenHan", 0x36: ",", 0x37: ".", 0x38: "/", 0x39: "CapsLock",
        0x3A: "F1", 0x3B: "F2", 0x3C: "F3", 0x3D: "F4", 0x3E: "F5", 0x3F: "F6", 0x40: "F7",
        0x41: "F8", 0x42: "F9", 0x43: "F10", 0x44: "F11", 0x45: "F12",
        0x46: "PrintScreen", 0x47: "ScrollLock", 0x48: "Pause", 0x49: "Insert", 0x4A: "Home",
        0x4B: "PageUp", 0x4C: "Delete", 0x4D: "End", 0x4E: "PageDown",
        0x4F: "→", 0x50: "←", 0x51: "↓", 0x52: "↑",
        0x53: "NumLock", 0x54: "Num/", 0x55: "Num*", 0x56: "Num-", 0x57: "Num+", 0x58: "NumEnter",
        0x59: "Num1", 0x5A: "Num2", 0x5B: "Num3", 0x5C: "Num4", 0x5D: "Num5", 0x5E: "Num6",
        0x5F: "Num7", 0x60: "Num8", 0x61: "Num9", 0x62: "Num0", 0x63: "Num.", 0x65: "Menu",
        0x68: "F13", 0x69: "F14", 0x6A: "F15", 0x6B: "F16", 0x6C: "F17", 0x6D: "F18", 0x6E: "F19",
        0x6F: "F20", 0x70: "F21", 0x71: "F22", 0x72: "F23", 0x73: "F24",
        0x87: "BackSL", 0x88: "k/Hira", 0x89: "￥", 0x8A: "変換", 0x8B: "無変換",
        0xE0: "Ctrl L", 0xE1: "Shift L", 0xE2: "Alt L", 0xE3: "Win L",
        0xE4: "Ctrl R", 0xE5: "Shift R", 0xE6: "Alt R", 0xE7: "Win R",
    ]

    public static func name(_ code: UInt8) -> String {
        if code == 0 { return "(none)" }
        return names[code] ?? String(format: "0x%02X", code)
    }

    /// Ordered list for UI pickers: "(none)" then every named key by usage id.
    public static let common: [NamedKey] =
        [NamedKey("(none)", 0)] + names.sorted { $0.key < $1.key }.map { NamedKey($1, $0) }
}
