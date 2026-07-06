import Foundation

/// Rev-O-mate config-interface wire protocol (Vendor HID, UsagePage 0xFF00).
///
/// Every transaction is one 64-byte OUT report -> one 64-byte IN report.
/// The opcode is byte 0 and is echoed back in the response byte 0.
/// `ans` convention (response byte 1): 0x00 = OK, 0xFF = NG. Read commands
/// instead put the returned byte count in that field.
///
/// NOTE ON ENDIANNESS: the address in the command header is **big-endian**
/// (4 bytes), while scalars stored *inside* the flash are little-endian.
public enum Command {
    public static let flashRead: UInt8 = 0x11  // read  (len <= 62)
    public static let flashWrite: UInt8 = 0x12  // write (len <= 58, no erase)
    public static let flashErase: UInt8 = 0x13  // 64 KiB sector erase
    public static let swState: UInt8 = 0x30
    public static let modeState: UInt8 = 0x31
    public static let version: UInt8 = 0x56  // firmware version / presence
    public static let ledGet: UInt8 = 0x62
    public static let ledSet: UInt8 = 0x63  // persistent live LED
    public static let ledPreview: UInt8 = 0x64  // temporary LED w/ timeout

    /// Max data bytes per single flash read (64 - 2 header bytes).
    public static let maxReadChunk = 62
    /// Max data bytes per single flash write (64 - 6 header bytes).
    public static let maxWriteChunk = 58

    /// Encode a flash address as the 4-byte big-endian header field.
    public static func beAddress(_ a: UInt32) -> [UInt8] {
        [
            UInt8((a >> 24) & 0xFF),
            UInt8((a >> 16) & 0xFF),
            UInt8((a >> 8) & 0xFF),
            UInt8(a & 0xFF),
        ]
    }
}
