import AppKit
import Carbon
import ApplicationServices
import RelayCore

@MainActor final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var pendingSpace: CGEvent?
    private var consumedHold = false
    private var sleepObservers: [NSObjectProtocol] = []
    private var hold = SpaceHoldGate()
    private var holdTask: Task<Void, Never>?
    private let commandModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
    var onShow: (() -> Void)?
    var onStop: (() -> Void)?
    var onVoice: (() -> Void)?
    var onHandsFree: (() -> Void)?
    var onSpaceStatus: ((Bool) -> Void)?
    var onSpaceHold: (() -> Void)?
    var onSpaceRelease: (() -> Void)?
    var onSpaceCancel: (() -> Void)?
    func register() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let owner = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in if id.id == 1 { owner.onShow?() } else if id.id == 2 { owner.onStop?() } else if id.id == 3 { owner.onVoice?() } else { owner.onHandsFree?() } }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        for (id, key) in [(UInt32(1), UInt32(kVK_Space)), (UInt32(2), UInt32(kVK_Escape)), (UInt32(3), UInt32(kVK_ANSI_V)), (UInt32(4), UInt32(kVK_ANSI_H))] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(key, UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x524C4159, id: id), GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
        // Both monitors are needed: global events exclude Relay's own windows.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleSpaceEvent(event)
            return event // Do not delay or consume ordinary typing.
        }
        refreshMonitoring()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelSpaceHold(); self?.pendingSpace = nil; self?.consumedHold = false }
            })
        }
    }

    func refreshMonitoring() {
        // Called again after permission changes; startup must not request permission.
        if AXIsProcessTrusted() {
            if eventTap == nil {
                let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
                eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { proxy, type, event, context in
                    guard let context else { return Unmanaged.passUnretained(event) }
                    return MainActor.assumeIsolated {
                        let owner = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
                        return owner.filterSpace(proxy: proxy, type: type, event: event)
                    }
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
                if let eventTap {
                    tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
                    if let tapSource { CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes) }
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }
            if eventTap != nil {
                onSpaceStatus?(true)
                if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
                if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
                return
            }
            onSpaceStatus?(false)
            guard globalMonitor == nil else { return }
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                self?.handleSpaceEvent(event)
            }
        } else {
            onSpaceStatus?(false)
            if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            if let eventTap { CFMachPortInvalidate(eventTap) }
            tapSource = nil; eventTap = nil; pendingSpace = nil; consumedHold = false
            cancelSpaceHold()
        }
    }

    // Buffer an ordinary Space until release. A tap emits one space; a long hold
    // becomes a voice gesture without repeating spaces or pausing the foreground app.
    private func filterSpace(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancelSpaceHold(); pendingSpace = nil; consumedHold = false
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Relay's own typing must not end the user's physical hold or start another one.
        if event.getIntegerValueField(.eventSourceUserData) == RelayKeyboardEvent.marker { return Unmanaged.passUnretained(event) }
        guard let native = NSEvent(cgEvent: event) else { return Unmanaged.passUnretained(event) }
        let space = native.keyCode == UInt16(kVK_Space)
        let modified = !native.modifierFlags.intersection(commandModifiers).isEmpty
        if type == .keyUp && space {
            let swallowed = consumedHold
            pendingSpace?.tapPostEvent(proxy)
            pendingSpace = nil; consumedHold = false
            handleSpaceEvent(native)
            return swallowed ? nil : Unmanaged.passUnretained(event)
        }
        if (type == .keyDown && !space) || (type == .flagsChanged && modified) {
            pendingSpace?.tapPostEvent(proxy); pendingSpace = nil
        }
        if type == .keyDown && space && !modified {
            if native.isARepeat { return pendingSpace != nil || consumedHold ? nil : Unmanaged.passUnretained(event) }
            pendingSpace = event.copy()
            handleSpaceEvent(native)
            return nil
        }
        handleSpaceEvent(native)
        return Unmanaged.passUnretained(event)
    }

    private func handleSpaceEvent(_ event: NSEvent) {
        let modified = !event.modifierFlags.intersection(commandModifiers).isEmpty
        if event.type == .flagsChanged {
            if modified { cancelSpaceHold() }
            return
        }
        guard event.keyCode == UInt16(kVK_Space) else {
            if event.type == .keyDown { cancelSpaceHold() }
            return
        }
        if event.type == .keyUp {
            holdTask?.cancel(); holdTask = nil
            if hold.release() { Task { @MainActor [weak self] in self?.onSpaceRelease?() } }
            return
        }
        if modified { cancelSpaceHold(); return }
        guard event.type == .keyDown,
              hold.press(at: ProcessInfo.processInfo.systemUptime, isRepeat: event.isARepeat, hasModifiers: modified) else { return }
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(SpaceHoldGate.duration * 1_000_000_000)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.holdTask = nil
            let down = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Space))
            let modifiedNow = !NSEvent.modifierFlags.intersection(self.commandModifiers).isEmpty
            if self.hold.activate(at: ProcessInfo.processInfo.systemUptime, spaceIsDown: down, hasModifiers: modifiedNow) {
                if self.eventTap != nil { self.pendingSpace = nil; self.consumedHold = true }
                self.onSpaceHold?()
            }
        }
    }

    private func cancelSpaceHold() {
        holdTask?.cancel(); holdTask = nil
        if hold.release() { Task { @MainActor [weak self] in self?.onSpaceCancel?() } }
    }

    func unregister() {
        cancelSpaceHold(); pendingSpace = nil; consumedHold = false
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        tapSource = nil; eventTap = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObservers.removeAll()
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}
