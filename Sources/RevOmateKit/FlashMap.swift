import Foundation

/// External SPI flash (M25P16, 2 MiB) layout, from the OSS protocol spec.
/// Addresses are absolute flash byte offsets.
public enum FlashMap {
    // Geometry
    public static let totalSize = 0x200000  // 2 MiB
    public static let sectorSize = 0x10000  // 64 KiB
    public static let sectorCount = 0x20  // 32
    public static let pageSize = 0x100  // 256 B

    // Logical regions
    public static let baseHeader: UInt32 = 0x000000  // ST_BASE_HEAD, 8 B
    public static let baseModeInfo: UInt32 = 0x000010  // stride 0x20  x3 modes
    public static let functionSetting: UInt32 = 0x000100  // stride 0x18  x12 (3*4)
    public static let functionNames: UInt32 = 0x000600  // stride 0x40  x12
    public static let encoderScript: UInt32 = 0x000A00  // stride 0x30  x3
    public static let swFunction: UInt32 = 0x000B00  // stride 0x08  x33 (3*11)
    public static let scriptHeader: UInt32 = 0x010000  // ST_SCRIPT_HEAD, 8 B
    public static let scriptInfo: UInt32 = 0x010010  // stride 0x110 x200 (1-based)
    public static let scriptData: UInt32 = 0x020000  // variable

    // Strides
    public static let baseModeStride: UInt32 = 0x20
    public static let functionStride: UInt32 = 0x18
    public static let functionNameStride: UInt32 = 0x40
    public static let encoderStride: UInt32 = 0x30
    public static let swStride: UInt32 = 0x08
    public static let scriptInfoStride: UInt32 = 0x110

    // Counts
    public static let modeCount = 3
    public static let functionsPerMode = 4
    public static let swCount = 11
    public static let encoderScriptCount = 3
    public static let scriptMax = 200

    /// SW index (0-based) of the dial's push button. The other 10 are the physical
    /// buttons SW1..SW10. Firmware `ENCODER_BUTTON_ID` / C# treats this one specially.
    public static let encoderButtonIndex = 10

    /// Display name for a 0-based SW index: SW1..SW10, and "Dial press" for the encoder button.
    public static func buttonName(_ index: Int) -> String {
        index == encoderButtonIndex ? "Dial press" : "SW\(index + 1)"
    }

    /// Address of a script-info record (1-based, matching the wire convention).
    public static func scriptInfoAddress(number: Int) -> UInt32 {
        precondition(number >= 1 && number <= scriptMax)
        return scriptInfo + scriptInfoStride * UInt32(number - 1)
    }
}
