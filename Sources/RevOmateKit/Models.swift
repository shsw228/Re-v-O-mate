import Foundation

// MARK: - Little-endian helpers (flash-internal scalars are LE)

@inline(__always) func u16le(_ b: [UInt8], _ o: Int) -> UInt16 {
    UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
}

@inline(__always) func u32le(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}

// MARK: - Parsed structures (skeleton; M2 will complete the set)

/// ST_SCRIPT_HEAD @ 0x010000 (8 bytes).
public struct ScriptHeader: Sendable {
    public var checksum: UInt16      // Check_SUM (algorithm TBD, spec §7-9)
    public var recordCount: UInt8    // Rec_Num
    public var totalSize: UInt32     // Script_Total_Size

    public init(_ bytes: [UInt8]) {
        precondition(bytes.count >= 8)
        checksum = u16le(bytes, 0)
        recordCount = bytes[2]
        totalSize = u32le(bytes, 4)
    }
}

/// ST_BASE_HEAD @ 0x000000 (8 bytes).
public struct BaseHeader: Sendable {
    public var mode: UInt8
    public var ledSleepDisabled: UInt8   // 0=sleep enabled, 1=disabled
    public var ledLightMode: UInt8       // 0=on,1=off
    public var ledLightFunc: UInt8       // 0=on,1=slow fade,2=flash
    public var ledOffTimeSec: UInt8      // default 60, max 180
    public var encoderTypematic: UInt8   // 0=repeat, 1=hold

    public init(_ bytes: [UInt8]) {
        precondition(bytes.count >= 6)
        mode = bytes[0]
        ledSleepDisabled = bytes[1]
        ledLightMode = bytes[2]
        ledLightFunc = bytes[3]
        ledOffTimeSec = bytes[4]
        encoderTypematic = bytes[5]
    }
}

/// ST_SCRIPT_INFO record (logical 10-byte header of a 0x110 slot).
public struct ScriptInfo: Sendable {
    public enum Mode: UInt8, Sendable {
        case oneShot = 0, loop = 1, fire = 2, hold = 3
    }
    public var address: UInt32       // Script_Adress (in data region)
    public var size: UInt32          // Script_Size
    public var mode: Mode?
    public var name: String

    public init(_ bytes: [UInt8]) {
        precondition(bytes.count >= 10)
        address = u32le(bytes, 0)
        size = u32le(bytes, 4)
        mode = Mode(rawValue: bytes[8])
        let nameLen = Int(bytes[9])
        let end = min(10 + nameLen, bytes.count)
        name = String(decoding: bytes[10..<end], as: UTF8.self)
    }
}
