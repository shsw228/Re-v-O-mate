import Foundation

// MARK: - Function (dial) setting  — ST_FUNC_INFO, 24 B, stride 0x18

/// One dial function: clockwise / counter-clockwise actions + LED.
public struct FunctionInfo: Sendable {
    public var cw: ActionRecord
    public var ccw: ActionRecord
    public var ledColorNo: UInt8
    public var ledColorFlag: UInt8  // 0=preset, 1=custom RGB
    public var ledRGB: (UInt8, UInt8, UInt8)
    public var ledBrightness: UInt8

    public init(_ bytes: ArraySlice<UInt8>) {
        let b = Array(bytes)
        precondition(b.count >= 22)
        cw = ActionRecord(b[0..<8])
        ccw = ActionRecord(b[8..<16])
        ledColorNo = b[16]
        ledColorFlag = b[17]
        ledRGB = (b[18], b[19], b[20])
        ledBrightness = b[21]
    }
}

// MARK: - Function name  — [1-byte length][UTF-16LE], stride 0x40

public enum FunctionName {
    /// Decode a length-prefixed UTF-16LE name. `length` is a BYTE count.
    public static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        let b = Array(bytes)
        guard let len = b.first, len > 0, len != 0xFF, 1 + Int(len) <= b.count else { return "" }
        let body = Array(b[1..<(1 + Int(len))])
        var scalars = [UInt16]()
        var i = 0
        while i + 1 < body.count {
            scalars.append(UInt16(body[i]) | (UInt16(body[i + 1]) << 8))
            i += 2
        }
        return String(decoding: scalars, as: UTF16.self)
    }
}

// MARK: - SW/button function  — ST_SW_FUNC_INFO, 8 B, stride 0x08

public struct SwFuncRecord: Sendable {
    public var action: ActionRecord
    public init(_ bytes: ArraySlice<UInt8>) { action = ActionRecord(bytes) }
    public var isEmpty: Bool { action.isEmpty }
}

// MARK: - Encoder script setting  — ST_ENCODER_SCRIPT_INFO, 48 B, stride 0x30

public struct EncoderScriptInfo: Sendable {
    public var recordCount: UInt8
    public var loop: Bool
    public var scriptNumbers: [UInt8]  // up to 32; trimmed to recordCount

    public init(_ bytes: ArraySlice<UInt8>) {
        let b = Array(bytes)
        precondition(b.count >= 48)
        recordCount = b[0]
        loop = b[1] == 1
        let all = Array(b[16..<48])
        scriptNumbers = Array(all.prefix(Int(min(recordCount, 32))))
    }
}

// MARK: - Base per-mode info  — ST_BASE_INFO, 32 B, stride 0x20
// NOTE: the sw arrays are exposed raw; their exact semantics are being confirmed
// against the C# source (values like 0x97/0x98 seen in real dumps).

public struct BaseModeInfo: Sendable {
    public var swExeScriptNo: [UInt8]  // bytes 0..10
    public var swSpFuncNo: [UInt8]  // bytes 11..21
    public var encoderFuncNo: UInt8  // byte 22
    public var ledColorNo: UInt8  // byte 23
    public var ledColorFlag: UInt8  // byte 24
    public var ledRGB: (UInt8, UInt8, UInt8)  // bytes 25..27
    public var ledBrightness: UInt8  // byte 28

    public init(_ bytes: ArraySlice<UInt8>) {
        let b = Array(bytes)
        precondition(b.count >= 29)
        swExeScriptNo = Array(b[0..<11])
        swSpFuncNo = Array(b[11..<22])
        encoderFuncNo = b[22]
        ledColorNo = b[23]
        ledColorFlag = b[24]
        ledRGB = (b[25], b[26], b[27])
        ledBrightness = b[28]
    }

    /// Per-button (1-based SW) assignment: a script number and/or special-function number
    /// (0 = unassigned). This is how buttons get behavior in the base-mode info — distinct
    /// from a direct action stored in the SW function record.
    public struct ButtonAssignment: Sendable {
        public let sw: Int  // 1-based
        public let scriptNo: UInt8  // 0 = none
        public let specialFuncNo: UInt8
    }

    public var buttonAssignments: [ButtonAssignment] {
        (0..<swExeScriptNo.count).compactMap { i in
            let s = swExeScriptNo[i], sp = swSpFuncNo[i]
            guard s != 0 || sp != 0 else { return nil }
            return ButtonAssignment(sw: i + 1, scriptNo: s, specialFuncNo: sp)
        }
    }
}

// MARK: - Whole-image parser (offline, from a 2 MiB dump)

/// Parses a full flash image into the config structures. Use for offline analysis
/// of a `dump` file, or feed it a live full read.
public struct ConfigImage: Sendable {
    public var base: BaseHeader
    public var modes: [BaseModeInfo]
    public var functions: [FunctionInfo]  // 12 = 3 modes x 4 funcs
    public var functionNames: [String]  // 12
    public var encoderScripts: [EncoderScriptInfo]  // 3
    public var swFunctions: [SwFuncRecord]  // 33 = 3 modes x 11
    public var scriptHeader: ScriptHeader
    public var scripts: [ScriptEntry]  // non-empty entries only (size > 0)

    /// A populated script slot: its 1-based number, info record, and decoded commands.
    public struct ScriptEntry: Sendable, Identifiable {
        public let number: Int
        public let info: ScriptInfo
        public let commands: [ScriptCommand]
        public let undecodedBytes: Int
        public var id: Int { number }
    }

    public init(_ d: [UInt8]) {
        precondition(d.count >= 0x030000, "image too small")
        func slice(_ addr: UInt32, _ len: Int) -> ArraySlice<UInt8> {
            let a = Int(addr); return d[a..<(a + len)]
        }

        base = BaseHeader(Array(slice(FlashMap.baseHeader, 8)))

        modes = (0..<FlashMap.modeCount).map { m in
            BaseModeInfo(slice(FlashMap.baseModeInfo + FlashMap.baseModeStride * UInt32(m), 32))
        }

        let funcCount = FlashMap.modeCount * FlashMap.functionsPerMode
        functions = (0..<funcCount).map { i in
            FunctionInfo(slice(FlashMap.functionSetting + FlashMap.functionStride * UInt32(i), 24))
        }
        functionNames = (0..<funcCount).map { i in
            FunctionName.decode(slice(FlashMap.functionNames + FlashMap.functionNameStride * UInt32(i), 0x40))
        }

        encoderScripts = (0..<FlashMap.encoderScriptCount).map { i in
            EncoderScriptInfo(slice(FlashMap.encoderScript + FlashMap.encoderStride * UInt32(i), 48))
        }

        let swTotal = FlashMap.modeCount * FlashMap.swCount
        swFunctions = (0..<swTotal).map { i in
            SwFuncRecord(slice(FlashMap.swFunction + FlashMap.swStride * UInt32(i), 8))
        }

        scriptHeader = ScriptHeader(Array(slice(FlashMap.scriptHeader, 8)))

        // Script info table: keep only populated slots (size > 0). On a raw device
        // dump this can be empty even when the header + packed data at 0x020000 are valid.
        scripts = (1...FlashMap.scriptMax).compactMap { n in
            let a = Int(FlashMap.scriptInfoAddress(number: n))
            let info = ScriptInfo(Array(d[a..<(a + 0x110)]))
            guard !info.isEmpty else { return nil }
            let da = Int(info.address), ds = Int(info.size)
            let raw = (da + ds <= d.count) ? Array(d[da..<(da + ds)]) : []
            let (cmds, rest) = ScriptDecoder.decode(raw)
            return ScriptEntry(number: n, info: info, commands: cmds, undecodedBytes: rest)
        }
    }
}
