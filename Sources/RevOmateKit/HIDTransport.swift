import Foundation
import IOKit
import IOKit.hid

public enum HIDError: Error, CustomStringConvertible {
    case deviceNotFound
    case openFailed(IOReturn)
    case setReportFailed(IOReturn)
    case timeout
    case badResponse(String)

    public var description: String {
        switch self {
        case .deviceNotFound:
            return "Rev-O-mate config interface (VID 0x22EA, UsagePage 0xFF00) not found. Is it connected?"
        case .openFailed(let r):
            return "IOHIDDeviceOpen/ManagerOpen failed: 0x\(String(r, radix: 16))"
        case .setReportFailed(let r):
            return "IOHIDDeviceSetReport failed: 0x\(String(r, radix: 16))"
        case .timeout:
            return "Timed out waiting for device response."
        case .badResponse(let s):
            return "Unexpected response: \(s)"
        }
    }
}

/// Synchronous request/response transport over the Rev-O-mate vendor HID
/// interface. Selects the interface by VID/PID + PrimaryUsagePage 0xFF00.
///
/// Reports are 64 bytes with no Report ID (report ID 0). One OUT report yields
/// exactly one IN report, delivered via an input-report callback pumped on a
/// dedicated run-loop thread.
public final class HIDTransport: @unchecked Sendable {
    public static let vendorID  = 0x22EA
    public static let productID = 0x004B
    public static let usagePage = 0xFF00
    public static let usage     = 0x01
    public static let reportSize = 64

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: HIDTransport.reportSize)

    private var runLoop: CFRunLoop?
    private var thread: Thread?

    private let ioQueue = DispatchQueue(label: "com.revomate.hid.io")  // serializes transactions
    private let respLock = NSCondition()
    private var response: [UInt8]?

    public init() {}

    deinit {
        inputBuffer.deallocate()
    }

    public func open() throws {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match ONLY the vendor-defined interface. Matching on VID/PID alone would
        // make IOHIDManagerOpen try to open the keyboard/mouse interfaces too, which
        // the OS holds exclusively -> kIOReturnExclusiveAccess.
        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: HIDTransport.vendorID,
            kIOHIDProductIDKey as String: HIDTransport.productID,
            kIOHIDDeviceUsagePageKey as String: HIDTransport.usagePage,
            kIOHIDDeviceUsageKey as String: HIDTransport.usage,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

        let openRes = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openRes == kIOReturnSuccess else { throw HIDError.openFailed(openRes) }
        self.manager = mgr

        guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
            throw HIDError.deviceNotFound
        }

        func intProp(_ d: IOHIDDevice, _ key: String) -> Int? {
            (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue
        }

        // Pick the vendor-defined interface (0xFF00 / usage 1) among the composite HID device.
        let vendorIF = devices.first { d in
            intProp(d, kIOHIDPrimaryUsagePageKey) == HIDTransport.usagePage &&
            intProp(d, kIOHIDPrimaryUsageKey) == HIDTransport.usage
        }
        guard let dev = vendorIF else { throw HIDError.deviceNotFound }

        let r = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw HIDError.openFailed(r) }
        self.device = dev

        // Schedule the input-report callback on a dedicated run-loop thread.
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self, let dev = self.device else { ready.signal(); return }
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(
                dev, self.inputBuffer, HIDTransport.reportSize,
                { context, _, _, _, _, report, length in
                    guard let context else { return }
                    Unmanaged<HIDTransport>.fromOpaque(context)
                        .takeUnretainedValue()
                        .handleInput(report, length)
                },
                ctx
            )
            IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            self.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "com.revomate.hid.runloop"
        t.start()
        self.thread = t
        ready.wait()
    }

    private func handleInput(_ report: UnsafeMutablePointer<UInt8>, _ length: CFIndex) {
        let n = min(Int(length), HIDTransport.reportSize)
        respLock.lock()
        response = Array(UnsafeBufferPointer(start: report, count: n))
        respLock.signal()
        respLock.unlock()
    }

    /// Send a payload (padded to 64 bytes with 0xFF) and return the 64-byte response.
    public func transact(_ payload: [UInt8], timeout: TimeInterval = 2.0) throws -> [UInt8] {
        try ioQueue.sync {
            guard let dev = device else { throw HIDError.deviceNotFound }

            var out = payload
            if out.count < HIDTransport.reportSize {
                out.append(contentsOf: repeatElement(0xFF, count: HIDTransport.reportSize - out.count))
            } else if out.count > HIDTransport.reportSize {
                out = Array(out.prefix(HIDTransport.reportSize))
            }

            respLock.lock()
            response = nil
            respLock.unlock()

            let r = out.withUnsafeBufferPointer { buf in
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, buf.baseAddress!, HIDTransport.reportSize)
            }
            guard r == kIOReturnSuccess else { throw HIDError.setReportFailed(r) }

            respLock.lock()
            defer { respLock.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while response == nil {
                if !respLock.wait(until: deadline) { throw HIDError.timeout }
            }
            return response!
        }
    }

    public func close() {
        if let rl = runLoop { CFRunLoopStop(rl) }
        if let dev = device { IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let mgr = manager { IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil
        manager = nil
        runLoop = nil
    }
}
