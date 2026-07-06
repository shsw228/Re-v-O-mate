import Foundation

/// High-level Rev-O-mate operations built on `HIDTransport`.
/// Opens the vendor interface on init. All calls are synchronous/blocking;
/// call from a background task (see `RevOmateApp`).
public final class RevOmateDevice: @unchecked Sendable {
    private let transport: HIDTransport

    public init() throws {
        transport = HIDTransport()
        try transport.open()
    }

    public func close() { transport.close() }

    // MARK: Version / presence (0x56)

    public func version() throws -> String {
        let resp = try transport.transact([Command.version])
        guard resp.first == Command.version else {
            throw HIDError.badResponse("version echo missing (got \(resp.prefix(4).hexString))")
        }
        let ascii = resp.dropFirst().prefix { $0 != 0x00 }
        return String(decoding: ascii, as: UTF8.self)
    }

    // MARK: Flash read (0x11)

    public func readFlash(address: UInt32, length: Int) throws -> [UInt8] {
        precondition(length >= 1 && length <= Command.maxReadChunk)
        var cmd: [UInt8] = [Command.flashRead]
        cmd.append(contentsOf: Command.beAddress(address))
        cmd.append(UInt8(length))

        let resp = try transport.transact(cmd)
        guard resp.first == Command.flashRead else {
            throw HIDError.badResponse("flashRead echo missing")
        }
        let n = Int(resp[1])
        guard n == length else {
            throw HIDError.badResponse("flashRead len \(n) != requested \(length) (NG / out of range?)")
        }
        return Array(resp[2..<(2 + n)])
    }

    /// Read an arbitrary range by chunking into 62-byte reads.
    public func readRange(address: UInt32, count: Int,
                          progress: ((_ done: Int, _ total: Int) -> Void)? = nil) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count)
        var addr = address
        var remaining = count
        while remaining > 0 {
            let chunk = min(Command.maxReadChunk, remaining)
            out.append(contentsOf: try readFlash(address: addr, length: chunk))
            addr += UInt32(chunk)
            remaining -= chunk
            progress?(count - remaining, count)
        }
        return out
    }

    /// Read the entire 2 MiB flash (backup).
    public func dumpAll(progress: ((_ done: Int, _ total: Int) -> Void)? = nil) throws -> [UInt8] {
        try readRange(address: 0, count: FlashMap.totalSize, progress: progress)
    }

    /// Fast read for the config UI: reads only the regions that hold settings —
    /// sector 0 (all config), the script header + info table, and the data of each
    /// populated script — into a 0xFF-filled 2 MiB buffer. ~120 KB vs 2 MiB, so it's
    /// a few seconds instead of a minute. NOT a full backup (empty area stays 0xFF).
    public func readConfigImage(progress: ((_ done: Int, _ total: Int) -> Void)? = nil) throws -> [UInt8] {
        var img = [UInt8](repeating: 0xFF, count: FlashMap.totalSize)
        let infoEnd = Int(FlashMap.scriptInfoAddress(number: FlashMap.scriptMax) + FlashMap.scriptInfoStride)
        let headerToInfo = infoEnd - Int(FlashMap.scriptHeader)
        let planned = FlashMap.sectorSize + headerToInfo
        var done = 0

        func load(_ addr: UInt32, _ len: Int) throws {
            let bytes = try readRange(address: addr, count: len) { d, _ in progress?(done + d, planned) }
            for (i, b) in bytes.enumerated() { img[Int(addr) + i] = b }
            done += len
        }

        try load(0, FlashMap.sectorSize)                              // sector 0: all config
        try load(FlashMap.scriptHeader, headerToInfo)                 // header + 200-slot info table

        for n in 1...FlashMap.scriptMax {                             // data of populated scripts
            let a = Int(FlashMap.scriptInfoAddress(number: n))
            let addr = u32le(Array(img[a..<(a + 4)]), 0)
            let size = u32le(Array(img[(a + 4)..<(a + 8)]), 0)
            if size > 0, addr != 0, Int(addr) + Int(size) <= img.count {
                let bytes = try readRange(address: addr, count: Int(size))
                for (i, b) in bytes.enumerated() { img[Int(addr) + i] = b }
            }
        }
        return img
    }

    // MARK: Flash write / erase (0x12 / 0x13)  — not exercised by the spike

    public func eraseSector(address: UInt32) throws {
        var cmd: [UInt8] = [Command.flashErase]
        cmd.append(contentsOf: Command.beAddress(address))
        let resp = try transport.transact(cmd, timeout: 5.0)
        guard resp.first == Command.flashErase, resp.count > 1, resp[1] == 0x00 else {
            throw HIDError.badResponse("sector erase NG @0x\(String(address, radix: 16))")
        }
    }

    public func writeFlash(address: UInt32, data: [UInt8]) throws {
        precondition(data.count >= 1 && data.count <= Command.maxWriteChunk)
        var cmd: [UInt8] = [Command.flashWrite]
        cmd.append(contentsOf: Command.beAddress(address))
        cmd.append(UInt8(data.count))
        cmd.append(contentsOf: data)
        let resp = try transport.transact(cmd)
        guard resp.first == Command.flashWrite, resp.count > 1, resp[1] == 0x00 else {
            throw HIDError.badResponse("write NG @0x\(String(address, radix: 16))")
        }
    }

    /// Write a contiguous region, chunking into ≤58-byte writes that never cross a
    /// 256-byte page boundary (M25P16 page-program wraps within a page otherwise).
    /// The target range MUST already be erased (sector erase leaves 0xFF).
    public func writeRegion(address: UInt32, data: [UInt8],
                            progress: ((_ done: Int, _ total: Int) -> Void)? = nil) throws {
        var addr = address
        var i = 0
        while i < data.count {
            let pageEnd = (addr & ~UInt32(FlashMap.pageSize - 1)) + UInt32(FlashMap.pageSize)
            let chunk = Int(min(UInt32(Command.maxWriteChunk), pageEnd - addr, UInt32(data.count - i)))
            try writeFlash(address: addr, data: Array(data[i..<(i + chunk)]))
            addr += UInt32(chunk)
            i += chunk
            progress?(i, data.count)
        }
    }

    /// Erase one 64 KiB sector and program `data` (must be exactly one sector).
    /// Only pages containing non-0xFF bytes are written (erase already leaves 0xFF).
    /// Returns whether the read-back matches (when `verify` is true).
    @discardableResult
    public func restoreSector(address: UInt32, data: [UInt8], verify: Bool = true) throws -> Bool {
        precondition(data.count == FlashMap.sectorSize)
        precondition(address % UInt32(FlashMap.sectorSize) == 0, "sector address must be aligned")
        try eraseSector(address: address)
        for pageOff in stride(from: 0, to: FlashMap.sectorSize, by: FlashMap.pageSize) {
            let page = Array(data[pageOff..<(pageOff + FlashMap.pageSize)])
            if page.contains(where: { $0 != 0xFF }) {
                try writeRegion(address: address + UInt32(pageOff), data: page)
            }
        }
        guard verify else { return true }
        return try readRange(address: address, count: FlashMap.sectorSize) == data
    }

    /// Restore a full 2 MiB image, touching only sectors that differ from the device.
    /// Pass `baseline` (a known-current image, e.g. from a preceding `dumpAll`) to
    /// diff in memory and skip re-reading every sector. Returns restored sector addresses.
    public func restoreImage(_ image: [UInt8], baseline: [UInt8]? = nil,
                             progress: ((_ sector: Int, _ total: Int, _ changed: Bool) -> Void)? = nil) throws -> [UInt32] {
        precondition(image.count == FlashMap.totalSize)
        precondition(baseline == nil || baseline!.count == FlashMap.totalSize)
        var restored: [UInt32] = []
        for s in 0..<FlashMap.sectorCount {
            let lo = s * FlashMap.sectorSize, hi = lo + FlashMap.sectorSize
            let addr = UInt32(lo)
            let want = Array(image[lo..<hi])
            let have: [UInt8]
            if let baseline { have = Array(baseline[lo..<hi]) }
            else { have = try readRange(address: addr, count: FlashMap.sectorSize) }
            let changed = have != want
            if changed {
                try restoreSector(address: addr, data: want)
                restored.append(addr)
            }
            progress?(s, FlashMap.sectorCount, changed)
        }
        return restored
    }

    // MARK: Live LED (structured commands — apply immediately, unlike raw flash)

    /// Set the LED output live (cmd 0x63). Applied immediately by firmware; this is
    /// the "instant reflection" path the official app uses while editing. RGB is
    /// 0..100 duty; brightness is a level 0..2. Not necessarily persisted per-mode.
    public func setLEDLive(r: UInt8, g: UInt8, b: UInt8, brightness: UInt8) throws {
        let ledDataNum: UInt8 = 3
        let resp = try transport.transact([Command.ledSet, ledDataNum, brightness,
                                           min(r, 100), min(g, 100), min(b, 100)])
        guard resp.first == Command.ledSet, resp.count > 1, resp[1] == 0x00 else {
            throw HIDError.badResponse("setLEDLive NG")
        }
    }

    /// Read the current live LED output (cmd 0x62): (brightness, r, g, b).
    public func getLEDLive() throws -> (brightness: UInt8, r: UInt8, g: UInt8, b: UInt8) {
        let resp = try transport.transact([Command.ledGet])
        guard resp.first == Command.ledGet, resp.count >= 6 else {
            throw HIDError.badResponse("getLEDLive")
        }
        return (resp[2], resp[3], resp[4], resp[5])
    }

    // MARK: Convenience parsed reads

    public func scriptHeader() throws -> ScriptHeader {
        ScriptHeader(try readFlash(address: FlashMap.scriptHeader, length: 8))
    }

    public func baseHeader() throws -> BaseHeader {
        BaseHeader(try readFlash(address: FlashMap.baseHeader, length: 8))
    }
}

extension Collection where Element == UInt8 {
    public var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
