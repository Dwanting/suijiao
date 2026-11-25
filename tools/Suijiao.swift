import AppKit
import ApplicationServices
import IOKit.hid
import SwiftUI
import Carbon

final class Controller: NSObject, NSApplicationDelegate {
    var manager: IOHIDManager!
    var status: NSStatusItem!
    var busy = false
    var captured = Set<CFHashCode>()
    var devices: [CFHashCode: IOHIDDevice] = [:]
    let pet = CompanionState()
    var panel: CompanionPanel!
    var dragOrigin: NSPoint?
    var dragMouseOrigin: NSPoint?
    var voiceActive = false
    var lastEvent = "尚未收到按键"
    var diagnosticTimer: Timer?
    var wakeHotKey: EventHotKeyRef?
    var wakeHandler: EventHandlerRef?
    var calibrationHotKey: EventHotKeyRef?
    var rememberedInput: AXUIElement?
    var pagerModifiers = Set<UInt32>()
    var pagerChord = false
    var lastWake = Date.distantPast
    var hotKeyStatus: OSStatus = -1

    func diagnostic() {
        let value: [String: Any] = ["accessibility": AXIsProcessTrusted(), "inputMonitoring": IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue, "capturedDevices": devices.count, "inputRemembered": rememberedInput != nil, "wakeHotKeyStatus": hotKeyStatus, "lastEvent": lastEvent, "status": status.button?.title ?? "", "updated": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/suijiao-runtime-status.json"), options: .atomic)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "随叫"
        let menu = NSMenu()
        menu.addItem(withTitle: "隐藏桌面小精灵", action: #selector(togglePet), keyEquivalent: "").target = self
        menu.addItem(withTitle: "连接 Free3", action: #selector(connect), keyEquivalent: "").target = self
        menu.addItem(withTitle: "授权辅助功能…", action: #selector(authorize), keyEquivalent: "").target = self
        menu.addItem(withTitle: "退出随叫", action: #selector(quit), keyEquivalent: "").target = self
        status.menu = menu
        showPet()
        connect()
        registerWakeHotKey()
        diagnostic()
        diagnosticTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.diagnostic() }
    }

    func registerWakeHotKey() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
            var keyID = EventHotKeyID()
            guard let event else { return OSStatus(eventNotHandledErr) }
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &keyID)
            if keyID.id == 2 { owner.rememberInput(); return noErr }
            owner.lastEvent = "Wake shortcut Control+Option+Command+J"
            owner.handle(0x10000)
            owner.diagnostic()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &wakeHandler)
        let id = EventHotKeyID(signature: 0x534a574b, id: 1)
        hotKeyStatus = RegisterEventHotKey(38, UInt32(controlKey | optionKey | cmdKey), id, GetApplicationEventTarget(), 0, &wakeHotKey)
        let calibrationID = EventHotKeyID(signature: 0x534a574b, id: 2)
        RegisterEventHotKey(34, UInt32(controlKey | optionKey | cmdKey), calibrationID, GetApplicationEventTarget(), 0, &calibrationHotKey)
        status.button?.title = hotKeyStatus == noErr ? "随叫" : "随叫 · 唤起快捷键冲突"
    }

    @objc func togglePet() {
        if panel?.isVisible == true {
            panel.orderOut(nil)
            status.menu?.items.first?.title = "显示桌面小精灵"
        } else {
            showPet()
        }
    }

    @objc func showPet() {
        if panel == nil {
            panel = CompanionPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 270), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            pet.drag = { [weak self] _, ended in
                guard let self else { return }
                if self.dragOrigin == nil {
                    self.dragOrigin = self.panel.frame.origin
                    self.dragMouseOrigin = NSEvent.mouseLocation
                }
                let start = self.dragOrigin!
                let point = NSEvent.mouseLocation
                let mouseStart = self.dragMouseOrigin!
                var position = NSPoint(x: start.x + point.x - mouseStart.x, y: start.y + point.y - mouseStart.y)
                let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main
                if let frame = screen?.visibleFrame {
                    position.x = min(max(position.x, frame.minX), frame.maxX - 250)
                    position.y = min(max(position.y, frame.minY), frame.maxY - 270)
                }
                self.panel.setFrameOrigin(position)
                if ended {
                    self.dragOrigin = nil
                    self.dragMouseOrigin = nil
                    UserDefaults.standard.set([position.x, position.y], forKey: "petPosition")
                }
            }
            panel.contentView = NSHostingView(rootView: CompanionView(state: pet))
            if let frame = NSScreen.main?.visibleFrame {
                let saved = UserDefaults.standard.array(forKey: "petPosition") as? [Double]
                let x = saved?.count == 2 ? saved![0] : frame.maxX - 280
                let y = saved?.count == 2 ? saved![1] : frame.minY + 45
                panel.setFrameOrigin(NSPoint(x: min(max(x, frame.minX), frame.maxX - 250), y: min(max(y, frame.minY), frame.maxY - 270)))
            }
        }
        panel.orderFrontRegardless()
        status.menu?.items.first?.title = "隐藏桌面小精灵"
    }

    func releaseDevices() {
        for device in devices.values {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(device, 0)
        }
        devices.removeAll()
        captured.removeAll()
        if manager != nil {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, 0)
            manager = nil
        }
    }

    @objc func authorize() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc func connect() {
        releaseDevices()
        manager = IOHIDManagerCreate(nil, 0)
        captured.removeAll()
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey:1452, kIOHIDProductIDKey:556] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context,
                  IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String == "Free3-P" else { return }
            let owner = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
            if IOHIDDeviceOpen(device, 0) == kIOReturnSuccess {
        IOHIDDeviceRegisterInputValueCallback(device, { context, result, _, value in
            guard result == kIOReturnSuccess, let context else { return }
            let element = IOHIDValueGetElement(value)
            let device = IOHIDElementGetDevice(element)
            guard IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String == "Free3-P",
                  IOHIDElementGetUsagePage(element) == 7 else { return }
            let owner = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
            guard owner.captured.contains(CFHash(device)) else { return }
            owner.lastEvent = "Free3 usage=\(IOHIDElementGetUsage(element))"
            owner.diagnostic()
            owner.pagerEvent(IOHIDElementGetUsage(element), down: IOHIDValueGetIntegerValue(value) != 0)
        }, context)
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                owner.captured.insert(CFHash(device))
                owner.devices[CFHash(device)] = device
                owner.status.button?.title = "随叫"
            } else { owner.status.button?.title = "随叫 · 设备连接失败" }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let owner = Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue()
            owner.captured.remove(CFHash(device))
            owner.devices.removeValue(forKey: CFHash(device))
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        status.button?.title = "随叫 · 等待 Free3"
    }

    func pagerEvent(_ usage: UInt32, down: Bool) {
        if [224, 226, 227].contains(usage) {
            if down {
                pagerModifiers.insert(usage)
                if usage == 224 { pagerChord = false }
                if usage != 224 { pagerChord = true }
            } else {
                pagerModifiers.remove(usage)
                if usage == 224 && !pagerChord {
                    voiceActive.toggle()
                    pet.mode = voiceActive ? .listening : .ready
                }
            }
            return
        }
        if down && usage == 13 && pagerModifiers.isSuperset(of: [224, 226, 227]) {
            pagerChord = true
            lastEvent = "Free3 wake chord received"
            handle(0x10000)
            diagnostic()
        }
    }

    func rememberInput() {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.openai.codex" else {
            status.button?.title = "随叫 · 请在 Codex 输入框中校准"
            diagnostic()
            return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let value = attribute(root, kAXFocusedUIElementAttribute as CFString) else { return }
        let input = unsafeBitCast(value, to: AXUIElement.self)
        let role = attribute(input, kAXRoleAttribute as CFString) as? String
        guard role == kAXTextAreaRole as String || role == kAXTextFieldRole as String else {
            status.button?.title = "随叫 · 请先点击聊天输入框"
            diagnostic()
            return
        }
        rememberedInput = input
        status.button?.title = "随叫 · 已记住输入框"
        lastEvent = "Input calibrated by user"
        diagnostic()
    }

    func handle(_ usage: UInt32) {
        guard usage == 0x10000, !busy, Date().timeIntervalSince(lastWake) > 0.7 else { return }
        lastWake = Date()
        busy = true
        pet.mode = .working
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { fail("没有找到 Codex 客户端"); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            DispatchQueue.main.async {
                guard let app else { self.fail("暂时无法打开 Codex"); return }
                app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                guard AXIsProcessTrusted() else {
                    self.status.button?.title = "随叫 · 已唤起，请授权输入框定位"
                    self.pet.mode = .ready
                    self.busy = false
                    self.diagnostic()
                    return
                }
                self.focus(app, usage: usage, remaining: 12)
            }
        }
    }

    func fail(_ note: String) {
        busy = false
        pet.mode = .problem
        status.button?.title = "随叫 · \(note)"
    }

    func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
    }

    func textAreas(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 25 else { return [] }
        if attribute(element, kAXRoleAttribute as CFString) as? String == kAXTextAreaRole as String,
           attribute(element, kAXEnabledAttribute as CFString) as? Bool != false {
            let hint = ["AXIdentifier", "AXPlaceholderValue", "AXDescription", "AXTitle"].compactMap { attribute(element, $0 as CFString) as? String }.joined(separator: " ").lowercased()
            if ["prompt", "message", "消息", "输入", "ask", "和codex", "和 codex"].contains(where: hint.contains) { return [element] }
        }
        let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
        return children.flatMap { textAreas($0, depth: depth + 1) }
    }

    func focus(_ app: NSRunningApplication, usage: UInt32, remaining: Int) {
        if let input = rememberedInput,
           AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            if let windowValue = attribute(input, kAXWindowAttribute as CFString) {
                let window = unsafeBitCast(windowValue, to: AXUIElement.self)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            status.button?.title = "随叫 · 输入框已定位"
            pet.mode = .ready
            busy = false
            diagnostic()
            return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let windows = attribute(root, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
        let focusedWindow = attribute(root, kAXFocusedWindowAttribute as CFString)
        let window: AXUIElement? = focusedWindow.map { unsafeBitCast($0, to: AXUIElement.self) } ?? windows.first
        let candidates = window.map { textAreas($0) } ?? []
        if candidates.count == 1, let input = candidates.first,
           AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            status.button?.title = "随叫"
            pet.mode = voiceActive ? .listening : .ready
            busy = false
        } else if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.focus(app, usage: usage, remaining: remaining - 1) }
        } else {
            status.button?.title = "随叫 · 请点输入框"
            fail("请点聊天输入框后按 ⌃⌥⌘I 校准")
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        releaseDevices()
        if let wakeHotKey { UnregisterEventHotKey(wakeHotKey) }
        if let calibrationHotKey { UnregisterEventHotKey(calibrationHotKey) }
        if let wakeHandler { RemoveEventHandler(wakeHandler) }
    }
}

@main
struct SuijiaoApplication {
    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-preview" {
            let state = CompanionState()
            let renderer = ImageRenderer(content: CompanionView(state: state))
            renderer.scale = 2
            if let cg = renderer.cgImage,
               let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            }
            return
        }
        let controller = Controller()
        app.setActivationPolicy(.accessory)
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
