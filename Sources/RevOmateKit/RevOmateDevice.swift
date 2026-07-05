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
