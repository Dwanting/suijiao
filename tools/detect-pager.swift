import Foundation
import IOKit.hid
import Darwin

// Only observe this pager over USB or its named Free3 Bluetooth interfaces.
let vendor = 0x4c4a
let product = 0x4155
let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
// IOHIDManager matching uses numeric hardware identifiers; product names are
// checked again below, rather than being used as unsupported matching keys.
let matching: [[String: Any]] = [
    [kIOHIDVendorIDKey: vendor, kIOHIDProductIDKey: product],
    [kIOHIDVendorIDKey: 1452, kIOHIDProductIDKey: 556]
]
IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)
var pressed: [String: TimeInterval] = [:]
var buffers: [UnsafeMutablePointer<UInt8>] = []
var attached: Set<CFHashCode> = []
let start = ProcessInfo.processInfo.systemUptime
let clock = ISO8601DateFormatter()

func report(_ line: String) {
    print("\(clock.string(from: Date())) \(line)")
    fflush(stdout)
}

func isPager(_ device: IOHIDDevice) -> Bool {
    let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
    let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
    let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "").lowercased()
    return (vid == vendor && pid == product) || (vid == 1452 && pid == 556 && name == "free3-p")
}

IOHIDManagerRegisterInputValueCallback(manager, { _, result, _, value in
    guard result == kIOReturnSuccess else { return }
    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    guard usage != 0, usage != UInt32.max else { return }
    let amount = IOHIDValueGetIntegerValue(value)
    let now = ProcessInfo.processInfo.systemUptime
    let device = IOHIDElementGetDevice(element)
    guard isPager(device) else { return }
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
    let key = "\(CFHash(device)):\(page):\(usage)"
    let elapsed = String(format: "%.3f", now - start)
    if amount != 0 {
        if pressed[key] == nil {
            pressed[key] = now
            report("\(elapsed)s DOWN device=\(name) page=\(page) usage=\(usage) value=\(amount)")
        } else {
            report("\(elapsed)s REPEAT page=\(page) usage=\(usage) value=\(amount)")
        }
    } else if let began = pressed.removeValue(forKey: key) {
        let duration = String(format: "%.3f", now - began)
        report("\(elapsed)s UP device=\(name) page=\(page) usage=\(usage) held=\(duration)s")
    }
}, nil)
IOHIDManagerRegisterDeviceMatchingCallback(manager, { _, result, _, device in
    guard result == kIOReturnSuccess, isPager(device), attached.insert(CFHash(device)).inserted else { return }
    let size = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 64
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(size, 64))
    buffers.append(buffer)
    IOHIDDeviceRegisterInputReportCallback(device, buffer, max(size, 64), { _, result, _, _, reportID, bytes, length in
        guard result == kIOReturnSuccess else { return }
        let data = UnsafeBufferPointer(start: bytes, count: length).map { String(format: "%02x", $0) }.joined(separator: " ")
        report("RAW id=\(reportID) bytes=\(data)")
    }, nil)
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
    let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "unknown"
    report("CONNECTED \(name); transport=\(transport); elements=\((IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement])?.count ?? 0)")
}, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, { _, _, _, device in
    guard attached.remove(CFHash(device)) != nil else { return }
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
    let prefix = "\(CFHash(device)):"
    for key in Array(pressed.keys) where key.hasPrefix(prefix) { pressed.removeValue(forKey: key) }
    report("DISCONNECTED \(name)")
}, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard result == kIOReturnSuccess else {
    report("OPEN_FAILED \(result); check Input Monitoring permission")
    exit(1)
}
report("ACCESS granted=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted)")
let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 600
report("READY observing USB pager and named Free3 Bluetooth devices; no events blocked; duration=\(seconds)s")
let heartbeat = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 30, 30, 0, 0) { _ in
    report("LISTENING elapsed=\(Int(ProcessInfo.processInfo.systemUptime - start))s")
}
CFRunLoopAddTimer(CFRunLoopGetCurrent(), heartbeat, .defaultMode)
CFRunLoopRunInMode(.defaultMode, seconds, false)
report("FINISHED pendingKeys=\(pressed.keys.sorted())")
CFRunLoopTimerInvalidate(heartbeat)
IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
for buffer in buffers { buffer.deallocate() }
