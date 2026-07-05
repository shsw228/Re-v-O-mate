import Foundation
import RevOmateKit

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "help"

do {
    switch cmd {
    case "version":
        let dev = try RevOmateDevice()
        defer { dev.close() }
        print("Firmware version: \(try dev.version())")

    case "probe":
        let dev = try RevOmateDevice()
        defer { dev.close() }
        print("Firmware version: \(try dev.version())")

        let base = try dev.readFlash(address: FlashMap.baseHeader, length: 8)
        print("baseHeader   @0x000000: \(base.hexString)")
        let bh = BaseHeader(base)
        print("  mode=\(bh.mode) ledOffTime=\(bh.ledOffTimeSec)s encoderTypematic=\(bh.encoderTypematic)")

        let sh = try dev.readFlash(address: FlashMap.scriptHeader, length: 8)
        print("scriptHeader @0x010000: \(sh.hexString)")
        let hdr = ScriptHeader(sh)
        print("  recordCount=\(hdr.recordCount) totalSize=\(hdr.totalSize) checksum=0x\(String(format: "%04X", hdr.checksum))")

        // First few script-info records, if any.
        let n = min(Int(hdr.recordCount), 5)
        if n > 0 {
            print("first \(n) script(s):")
            for i in 1...n {
                let raw = try dev.readFlash(address: FlashMap.scriptInfoAddress(number: i), length: 32)
                let info = ScriptInfo(raw)
                print("  #\(i) mode=\(info.mode.map { "\($0)" } ?? "?") size=\(info.size) addr=0x\(String(info.address, radix: 16)) name=\"\(info.name)\"")
            }
        }

    case "peek":
        // peek <hexAddr> [len]  — raw flash hex/ascii dump for reverse engineering.
        guard args.count >= 2, let addr = UInt32(args[1].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            err("usage: revomate peek <hexAddr> [len]"); exit(2)
        }
        let len = args.count >= 3 ? (Int(args[2]) ?? 64) : 64
        let dev = try RevOmateDevice()
        defer { dev.close() }
        let bytes = try dev.readRange(address: addr, count: len)
        var i = 0
        while i < bytes.count {
            let row = Array(bytes[i..<min(i + 16, bytes.count)])
            let hex = row.hexString.padding(toLength: 47, withPad: " ", startingAt: 0)
            let ascii = String(row.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            print(String(format: "0x%06X  %@  %@", Int(addr) + i, hex, ascii))
            i += 16
        }

    case "config":
        // config [dumpFile]  — parse a flash image into a readable config summary.
        // With no file it does a live full read from the device.
        let image: [UInt8]
        if args.count >= 2 {
            image = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))
        } else {
            let dev = try RevOmateDevice(); defer { dev.close() }
            err("Reading flash from device…")
            image = try dev.dumpAll()
        }
        let cfg = ConfigImage(image)
        print("Base: mode=\(cfg.base.mode) ledOffTime=\(cfg.base.ledOffTimeSec)s encoderTypematic=\(cfg.base.encoderTypematic)")
        print("Script header: recordCount=\(cfg.scriptHeader.recordCount) totalSize=\(cfg.scriptHeader.totalSize)")
        for m in 0..<FlashMap.modeCount {
            let mode = cfg.modes[m]
            print("\n── Mode \(m) ── encoderFunc=\(mode.encoderFuncNo) LED(color=\(mode.ledColorNo) flag=\(mode.ledColorFlag) rgb=\(mode.ledRGB.0),\(mode.ledRGB.1),\(mode.ledRGB.2) bright=\(mode.ledBrightness))")
            print("  Dial functions:")
            for f in 0..<FlashMap.functionsPerMode {
                let idx = m * FlashMap.functionsPerMode + f
                let fn = cfg.functions[idx]
                let name = cfg.functionNames[idx]
                let marker = f == Int(mode.encoderFuncNo) ? "●" : " "
                print("   \(marker)[\(f)] \"\(name)\"  CW: \(fn.cw.describe()) [sense \(fn.cw.sense)]   CCW: \(fn.ccw.describe()) [sense \(fn.ccw.sense)]")
            }
            // Buttons get behaviour from base-mode assignments (script/special func)
            // and/or a direct action in the SW function record.
            print("  Buttons:")
            var anyButton = false
            for s in 0..<FlashMap.swCount {
                var parts: [String] = []
                let script = mode.swExeScriptNo[s], sp = mode.swSpFuncNo[s]
                if script != 0 { parts.append("script #\(script)") }
                if sp != 0 { parts.append("spFunc \(sp)") }
                let direct = cfg.swFunctions[m * FlashMap.swCount + s]
                if !direct.isEmpty { parts.append("action \(direct.action.describe())") }
                if !parts.isEmpty { anyButton = true; print("    SW\(s + 1): \(parts.joined(separator: ", "))") }
            }
            if !anyButton { print("    (none assigned)") }
        }

        // Script table (populated slots only; may be empty on a raw dump).
        print("\n── Scripts ──")
        if cfg.scripts.isEmpty {
            print("  (info table empty; \(cfg.scriptHeader.recordCount) record(s), \(cfg.scriptHeader.totalSize) B packed @0x020000)")
        } else {
            for s in cfg.scripts {
                let a = Int(s.address), n = Int(s.size)
                let raw = (a + n <= image.count) ? Array(image[a..<(a + n)]) : []
                let (cmds, rest) = ScriptDecoder.decode(raw)
                let body = cmds.map { c in
                    c.data.isEmpty ? "\(c.opcode)" : "\(c.opcode)(\(c.data.hexString))"
                }.joined(separator: " → ")
                let tail = rest > 0 ? " [+\(rest)B undecoded]" : ""
                print("  mode=\(s.mode.map { "\($0)" } ?? "?") size=\(s.size) @0x\(String(s.address, radix: 16)) \"\(s.name)\": \(body)\(tail)")
            }
        }

    case "dump":
        guard args.count >= 2 else { err("usage: revomate dump <path>"); exit(2) }
        let path = args[1]
        let dev = try RevOmateDevice()
        defer { dev.close() }
        err("Dumping \(FlashMap.totalSize / 1024) KiB flash to \(path) ...")
        let start = Date()
        var lastPct = -1
        let data = try dev.dumpAll { done, total in
            let pct = done * 100 / total
            if pct != lastPct && pct % 10 == 0 { err("  \(pct)%"); lastPct = pct }
        }
        try Data(data).write(to: URL(fileURLWithPath: path))
        let secs = Date().timeIntervalSince(start)
        print("Wrote \(data.count) bytes in \(String(format: "%.1f", secs))s")

    default:
        print("""
        revomate — Rev-O-mate CLI (connectivity spike)

        commands:
          version         read firmware version (cmd 0x56)
          probe           version + base/script headers + first scripts
          peek <a> [len]  raw hex/ascii dump of a flash range
          config [file]   parse flash (device, or a dump file) into a readable summary
          dump <path>     read entire 2 MiB flash to a .bin file (backup)
        """)
    }
} catch {
    err("Error: \(error)")
    exit(1)
}
