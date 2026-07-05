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
          version        read firmware version (cmd 0x56)
          probe          version + base/script headers + first scripts
          dump <path>    read entire 2 MiB flash to a .bin file (backup)
        """)
    }
} catch {
    err("Error: \(error)")
    exit(1)
}
