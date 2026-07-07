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
        print(
            "  recordCount=\(hdr.recordCount) totalSize=\(hdr.totalSize) checksum=0x\(String(format: "%04X", hdr.checksum))"
        )

        // First few script-info records, if any.
        let n = min(Int(hdr.recordCount), 5)
        if n > 0 {
            print("first \(n) script(s):")
            for i in 1...n {
                let raw = try dev.readFlash(address: FlashMap.scriptInfoAddress(number: i), length: 32)
                let info = ScriptInfo(raw)
                print(
                    "  #\(i) mode=\(info.mode.map { "\($0)" } ?? "?") size=\(info.size) addr=0x\(String(info.address, radix: 16)) name=\"\(info.name)\""
                )
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
        print(
            "Base: mode=\(cfg.base.mode) ledOffTime=\(cfg.base.ledOffTimeSec)s encoderTypematic=\(cfg.base.encoderTypematic)"
        )
        print("Script header: recordCount=\(cfg.scriptHeader.recordCount) totalSize=\(cfg.scriptHeader.totalSize)")
        for m in 0..<FlashMap.modeCount {
            let mode = cfg.modes[m]
            print(
                "\n── Mode \(m) ── encoderFunc=\(mode.encoderFuncNo) LED(color=\(mode.ledColorNo) flag=\(mode.ledColorFlag) rgb=\(mode.ledRGB.0),\(mode.ledRGB.1),\(mode.ledRGB.2) bright=\(mode.ledBrightness))"
            )
            print("  Dial functions:")
            for f in 0..<FlashMap.functionsPerMode {
                let idx = m * FlashMap.functionsPerMode + f
                let fn = cfg.functions[idx]
                let name = cfg.functionNames[idx]
                let marker = f == Int(mode.encoderFuncNo) ? "●" : " "
                print(
                    "   \(marker)[\(f)] \"\(name)\"  CW: \(fn.cw.describe()) [sense \(fn.cw.sense)]   CCW: \(fn.ccw.describe()) [sense \(fn.ccw.sense)]"
                )
            }
            // Buttons get behaviour from base-mode assignments (script/special func)
            // and/or a direct action in the SW function record.
            print("  Buttons:")
            var anyButton = false
            for s in 0..<FlashMap.swCount {
                var parts: [String] = []
                let script = mode.swExeScriptNo[s], sp = mode.swSpFuncNo[s]
                if script != 0 { parts.append("script #\(script)") }
                if sp != 0 { parts.append("spFunc \(sp) (\(SpecialFunction.name(sp)))") }
                let direct = cfg.swFunctions[m * FlashMap.swCount + s]
                if !direct.isEmpty { parts.append("action \(direct.action.describe())") }
                if !parts.isEmpty { anyButton = true; print("    SW\(s + 1): \(parts.joined(separator: ", "))") }
            }
            if !anyButton { print("    (none assigned)") }
        }

        // Script table (populated slots only; may be empty on a raw dump).
        print("\n── Scripts ──")
        if cfg.scripts.isEmpty {
            print(
                "  (info table empty; \(cfg.scriptHeader.recordCount) record(s), \(cfg.scriptHeader.totalSize) B packed @0x020000)"
            )
        } else {
            for s in cfg.scripts {
                let body = s.commands.map { $0.describe }.joined(separator: " → ")
                let tail = s.undecodedBytes > 0 ? " [+\(s.undecodedBytes)B undecoded]" : ""
                print(
                    "  #\(s.number) mode=\(s.info.mode.map { "\($0)" } ?? "?") size=\(s.info.size) @0x\(String(s.info.address, radix: 16)) \"\(s.info.name)\": \(body)\(tail)"
                )
            }
        }

    case "verify":
        // verify <file>  — read whole flash and compare to a file (read-only, safe).
        guard args.count >= 2 else { err("usage: revomate verify <file>"); exit(2) }
        let want = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))
        let dev = try RevOmateDevice(); defer { dev.close() }
        err("Reading flash to compare…")
        let have = try dev.dumpAll()
        if have == want {
            print("MATCH — device flash is identical to \(args[1]) (\(have.count) bytes)")
        } else {
            let diffs = zip(have, want).enumerated().filter { $0.element.0 != $0.element.1 }
            let first = diffs.first.map { "0x\(String($0.offset, radix: 16))" } ?? "?"
            print(
                "DIFFER — \(diffs.count) byte(s) differ (first @\(first)); sizes have=\(have.count) want=\(want.count)")
        }

    case "restore-sector":
        // restore-sector <file> <hexAddr>  — erase+write ONE 64 KiB sector, then verify.
        guard args.count >= 3, let raw = UInt32(args[2].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            err("usage: revomate restore-sector <file> <hexAddr>"); exit(2)
        }
        let image = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))
        guard image.count == FlashMap.totalSize else { err("file is not a 2 MiB image"); exit(2) }
        let addr = raw & ~UInt32(FlashMap.sectorSize - 1)
        let sector = Array(image[Int(addr)..<Int(addr) + FlashMap.sectorSize])
        let dev = try RevOmateDevice(); defer { dev.close() }
        err("Erasing + writing sector @0x\(String(addr, radix: 16))…")
        let ok = try dev.restoreSector(address: addr, data: sector, verify: true)
        print(
            ok
                ? "OK — sector @0x\(String(addr, radix: 16)) restored and verified"
                : "FAIL — read-back mismatch @0x\(String(addr, radix: 16))")
        if !ok { exit(1) }

    case "restore":
        // restore <file>  — restore a full 2 MiB backup, touching only changed sectors.
        guard args.count >= 2 else { err("usage: revomate restore <file>"); exit(2) }
        let image = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))
        guard image.count == FlashMap.totalSize else { err("file is not a 2 MiB image"); exit(2) }
        let dev = try RevOmateDevice(); defer { dev.close() }
        err("Restoring \(args[1]) (only changed sectors)…")
        let restored = try dev.restoreImage(image) { s, total, changed in
            if changed { err("  sector \(s)/\(total) @0x\(String(s * FlashMap.sectorSize, radix: 16)) rewritten") }
        }
        print("Done — \(restored.count) sector(s) rewritten\(restored.isEmpty ? " (device already matched)" : "")")

    case "roundtrip":
        // roundtrip <dump>  — offline check that ActionRecord parse→encode is byte-exact.
        guard args.count >= 2 else { err("usage: revomate roundtrip <dump>"); exit(2) }
        let d = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))
        guard d.count == FlashMap.totalSize else { err("not a 2 MiB image"); exit(2) }
        var checked = 0, bad = 0
        func check(_ addr: Int, _ label: String) {
            let orig = Array(d[addr..<addr + 8])
            let re = ActionRecord(orig[...]).encoded
            checked += 1
            if re != orig {
                bad += 1;
                print("  MISMATCH \(label) @0x\(String(addr, radix: 16)): \(orig.hexString) -> \(re.hexString)")
            }
        }
        for m in 0..<FlashMap.modeCount {
            for f in 0..<FlashMap.functionsPerMode {
                let base =
                    Int(FlashMap.functionSetting) + (m * FlashMap.functionsPerMode + f) * Int(FlashMap.functionStride)
                check(base, "m\(m)f\(f).CW"); check(base + 8, "m\(m)f\(f).CCW")
            }
            for s in 0..<FlashMap.swCount {
                check(Int(FlashMap.swFunction) + (m * FlashMap.swCount + s) * Int(FlashMap.swStride), "m\(m)SW\(s + 1)")
            }
        }
        print("roundtrip: \(checked) records checked, \(bad) mismatch(es) — \(bad == 0 ? "OK" : "FAIL")")
        // Also validate script bytecode decode -> encode is byte-exact.
        let cfg = ConfigImage(d)
        var sChecked = 0, sBad = 0
        for s in cfg.scripts {
            let a = Int(s.info.address), n = Int(s.info.size)
            guard a + n <= d.count else { continue }
            let orig = Array(d[a..<a + n])
            let re = ScriptEncoder.encode(s.commands)
            sChecked += 1
            if s.undecodedBytes != 0 || re != orig {
                sBad += 1;
                print(
                    "  SCRIPT MISMATCH @0x\(String(a, radix: 16)): \(orig.hexString) -> \(re.hexString) (undecoded \(s.undecodedBytes))"
                )
            }
        }
        print("script roundtrip: \(sChecked) checked, \(sBad) mismatch(es) — \(sBad == 0 ? "OK" : "FAIL")")

    case "led":
        // led <r> <g> <b> [brightness]  — LIVE LED set (cmd 0x63), instant, not persisted.
        guard args.count >= 4, let r = UInt8(args[1]), let g = UInt8(args[2]), let b = UInt8(args[3]) else {
            err("usage: revomate led <r 0-100> <g> <b> [brightness 0-2]"); exit(2)
        }
        let bright = args.count >= 5 ? (UInt8(args[4]) ?? 1) : 1
        let dev = try RevOmateDevice(); defer { dev.close() }
        let before = try dev.getLEDLive()
        try dev.setLEDLive(r: r, g: g, b: b, brightness: bright)
        print(
            "LED set live to \(r),\(g),\(b) bright=\(bright) (was \(before.r),\(before.g),\(before.b) bright=\(before.brightness))"
        )

    case "set-led":
        // set-led <mode> <r> <g> <b> [brightness]  — edit per-mode LED, write back, verify.
        guard args.count >= 5, let mode = Int(args[1]),
            let r = UInt8(args[2]), let g = UInt8(args[3]), let b = UInt8(args[4])
        else {
            err("usage: revomate set-led <mode 0-2> <r 0-100> <g> <b> [brightness 0-2]"); exit(2)
        }
        guard (0..<FlashMap.modeCount).contains(mode) else { err("mode must be 0..\(FlashMap.modeCount - 1)"); exit(2) }
        guard r <= 100, g <= 100, b <= 100 else { err("RGB must be 0..100"); exit(2) }
        guard args.count < 6 || (UInt8(args[5]).map { $0 <= 2 } ?? false) else {
            err("brightness must be 0..2"); exit(2)
        }
        let bright = args.count >= 6 ? (UInt8(args[5]) ?? 1) : 1
        let dev = try RevOmateDevice(); defer { dev.close() }
        err("Reading current flash…")
        let current = try dev.dumpAll()
        var editor = ConfigEditor(current)
        editor.setModeLED(mode: mode, colorNo: 0, useCustomRGB: true, rgb: (r, g, b), brightness: bright)
        err("Writing changed sector(s)…")
        let restored = try dev.restoreImage(editor.image, baseline: current)
        // Read back just the mode LED bytes to confirm persistence.
        let addr = FlashMap.baseModeInfo + FlashMap.baseModeStride * UInt32(mode) + 23
        let back = try dev.readFlash(address: addr, length: 6)
        print(
            "Wrote \(restored.count) sector(s). Mode \(mode) LED now: colorNo=\(back[0]) flag=\(back[1]) rgb=\(back[2]),\(back[3]),\(back[4]) bright=\(back[5])"
        )
        print(back[2] == r && back[3] == g && back[4] == b ? "OK — persisted in flash" : "MISMATCH — not persisted")

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
        print(
            """
            revomate — Rev-O-mate CLI (connectivity spike)

            commands:
              version         read firmware version (cmd 0x56)
              probe           version + base/script headers + first scripts
              peek <a> [len]  raw hex/ascii dump of a flash range
              config [file]   parse flash (device, or a dump file) into a readable summary
              dump <path>     read entire 2 MiB flash to a .bin file (backup)
              verify <file>   read flash and compare to a backup (read-only)
              restore-sector <file> <hexAddr>   erase+write ONE sector, then verify
              restore <file>  restore a full 2 MiB backup (only changed sectors)
            """)
    }
} catch {
    err("Error: \(error)")
    exit(1)
}
