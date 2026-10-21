import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision
import RelayCore

@MainActor final class MacComputer: Computer {
    private var nodes: [Int: AXNode] = [:]
    private var observedPID: pid_t = 0
    private var observedWindow = ""
    private var targetApp: NSRunningApplication?
    var currentTargetPID: pid_t? { targetApp?.processIdentifier }
    private var allowedPIDs = Set<pid_t>()
    private var captureFrame = CGRect.zero
    private var clipboardBaseline: Int?
    private let screenshots: Bool
    private let task: String
    private let appCatalog = AppCatalog.discover()
    init(screenshots: Bool, initialApp: NSRunningApplication?, task: String = "") {
        self.screenshots = screenshots; targetApp = initialApp; self.task = task
        if let initialApp { allowedPIDs.insert(initialApp.processIdentifier) }
    }
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenGranted: Bool { CGPreflightScreenCaptureAccess() }
    private let blockedApps = ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.Passwords", "com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop", "com.apple.ScriptEditor2"]
    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success else { return nil }
        return v
    }
    private func string(_ element: AXUIElement, _ attribute: String) -> String { value(element, attribute) as? String ?? "" }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero; var s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
    private func safeApp(_ app: NSRunningApplication) throws {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw RelayError.message("Switch to the app you want Relay to control, then resume.") }
        guard !blockedApps.contains(app.bundleIdentifier ?? "") else { throw RelayError.message("This app requires you to take over. Switch to an ordinary app before resuming.") }
    }
    private func resolveTarget() async throws -> NSRunningApplication {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            guard allowedPIDs.contains(front.processIdentifier) else { throw RelayError.message("You switched to an app outside this task. Return to the selected app or start a new task there.") }
            targetApp = front
        }
        guard let app = targetApp, !app.isTerminated else { throw RelayError.message("Open the app you want to control before starting.") }
        try safeApp(app)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            app.activate(options: [])
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return app
    }
    func observe() async throws -> Observation {
        guard Self.accessibilityGranted else { throw RelayError.message("Enable Accessibility for Relay in System Settings, then resume.") }
        if let direct = DirectWorkflow(task), let first = direct.steps.first,
           [.openApp, .openURL].contains(first.action.kind),
           targetApp == nil || targetApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier || blockedApps.contains(targetApp?.bundleIdentifier ?? "") {
            return Observation(application: "No target selected", tree: "")
        }
        let app = try await resolveTarget()
        try Task.checkCancellation()
        observedPID = app.processIdentifier
        let scanPID = observedPID
        let snapshot = await Task.detached(priority: .userInitiated) { AXScanner.read(pid: scanPID) }.value
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == scanPID else { throw RelayError.message("The app changed while reading its controls.") }
        observedWindow = snapshot.window
        nodes = snapshot.nodes
        var lines = snapshot.lines
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !blockedApps.contains($0.bundleIdentifier ?? "") && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }.map { "\($0.localizedName ?? "App") [\($0.bundleIdentifier ?? "") ]" }.joined(separator: ", ")
        lines.append("Running apps: \(running)")
        var candidates: [ActionCandidate] = []
        let appInstruction = PrivateTask(task).instruction
        let prioritized = appCatalog.sorted { a, b in
            let am = a.aliases.contains { task.localizedCaseInsensitiveContains($0) }, bm = b.aliases.contains { task.localizedCaseInsensitiveContains($0) }
            return am != bm ? am : a.name < b.name
        }
        for item in prioritized.prefix(65) where !blockedApps.contains(item.id) && item.aliases.contains(where: { alias in
            appInstruction.range(of: "\\b" + NSRegularExpression.escapedPattern(for: alias) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }) {
            candidates.append(ActionCandidate("Open application \(item.name) (\(item.aliases.joined(separator: ", ")))", Action(kind: .openApp, text: item.id)))
        }
        for id in nodes.keys.sorted() {
            guard let node = nodes[id] else { continue }
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(node.role) {
                candidates.append(ActionCandidate("Focus editable field [\(id)] \(node.label)", Action(kind: .focus, target: id)))
            } else {
                if node.pressable {
                    candidates.append(ActionCandidate("Click [\(id)] \(node.role) \(node.label)", Action(kind: .click, target: id)))
                }
            }
        }
        var labels = nodes.mapValues(\.label)
        var controls = snapshot.controls
        labels[9000] = "Active application: \(app.localizedName ?? "App"); window: \(observedWindow)"
        var image: Data?
        if screenshots && DirectWorkflow(task) == nil {
            guard Self.screenGranted else { throw RelayError.message("Enable Screen Recording for Relay, or turn off screenshots in Setup.") }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.filter({ $0.owningApplication?.processID == observedPID && $0.windowLayer == 0 }).sorted(by: { ($0.title == observedWindow ? 0 : 1) < ($1.title == observedWindow ? 0 : 1) }).first else { throw RelayError.message("No visible window is available for this app.") }
            captureFrame = target.frame
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let config = SCStreamConfiguration()
            let scale = min(1, 1400 / max(captureFrame.width, 1))
            config.width = max(1, Int(captureFrame.width * scale)); config.height = max(1, Int(captureFrame.height * scale))
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            image = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
            // OCR stays local; the restricted planner projects only permitted control names or opaque references.
            let recognized = try await Task.detached(priority: .userInitiated) {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
                return request.results ?? []
            }.value
            try Task.checkCancellation()
            for (offset, result) in recognized.prefix(55).enumerated() {
                guard let text = result.topCandidates(1).first?.string, !text.isEmpty else { continue }
                let id = 1000 + offset
                labels[id] = text
                lines.append("[OCR \(id)] \(text)")
                controls.append(ObservedControl(id: id, role: "OCRText", caption: text, value: text))
                if !nodes.values.contains(where: { $0.label.localizedCaseInsensitiveContains(text) }) {
                    let box = result.boundingBox
                    candidates.append(ActionCandidate("Click OCR text \(text) (coordinate; requires review)", Action(kind: .click, x: box.midX, y: 1 - box.midY), sourceID: id))
                }
            }
        } else { captureFrame = .zero }
        return Observation(application: app.localizedName ?? "App", window: observedWindow, tree: lines.joined(separator: "\n"), image: image, labels: labels, identity: "\(observedPID):\(observedWindow)", candidates: candidates, controls: controls, bundleID: app.bundleIdentifier ?? "", selectionCopied: clipboardBaseline.map { NSPasteboard.general.changeCount != $0 } ?? false)
    }
    func execute(_ action: Action, observation: Observation) async throws -> String {
        try Task.checkCancellation()
        try action.validate()
        if action.kind == .openApp {
            let name = action.text!
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) ?? ["/System/Applications/", "/Applications/", "/System/Applications/Utilities/"].map { URL(fileURLWithPath: $0).appendingPathComponent(name.hasSuffix(".app") ? name : name + ".app") }.first { FileManager.default.fileExists(atPath: $0.path) }
            guard let url, let bundle = Bundle(url: url), !blockedApps.contains(bundle.bundleIdentifier ?? ""), bundle.bundleIdentifier != Bundle.main.bundleIdentifier else { throw RelayError.message("App not found or requires a user handoff.") }
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            config.createsNewApplicationInstance = await ChromeLaunch.needsVisibleInstance(for: bundle.bundleIdentifier)
            try Task.checkCancellation()
            targetApp = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
            if let targetApp { allowedPIDs.insert(targetApp.processIdentifier) }
            return "Opened \(name); verify the new window."
        }
        if action.kind == .openURL {
            let url = URL(string: action.text!)!
            let browserIDs = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"]
            let activeID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let requested = action.application ?? (browserIDs.contains(activeID) ? activeID : nil)
            if let requested {
                guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: requested) else { throw RelayError.message("The requested browser is not installed. Choose another browser.") }
                let config = NSWorkspace.OpenConfiguration(); config.activates = true
                config.createsNewApplicationInstance = await ChromeLaunch.needsVisibleInstance(for: requested)
                try Task.checkCancellation()
                targetApp = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
                if let targetApp { allowedPIDs.insert(targetApp.processIdentifier) }
            } else {
                guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { throw RelayError.message("No default browser is available.") }
                let config = NSWorkspace.OpenConfiguration(); config.activates = true
                config.createsNewApplicationInstance = await ChromeLaunch.needsVisibleInstance(for: Bundle(url: appURL)?.bundleIdentifier)
                try Task.checkCancellation()
                targetApp = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
                if let targetApp { allowedPIDs.insert(targetApp.processIdentifier) }
            }
            return "Opened URL in the requested or active browser; verify the page."
        }
        if action.kind == .wait {
            try await Task.sleep(nanoseconds: UInt64(min(3000, max(100, action.amount ?? 500))) * 1_000_000)
            return "Waited for UI."
        }
        if action.kind == .observe { return "Requested a fresh observation." }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == observedPID else { throw RelayError.message("The foreground app changed. Observe again before acting.") }
        let appRoot = AXUIElementCreateApplication(observedPID)
        if let focused = value(appRoot, kAXFocusedUIElementAttribute), string(focused as! AXUIElement, kAXSubroleAttribute) == kAXSecureTextFieldSubrole {
            throw RelayError.message("A secure field is focused. Enter credentials yourself.")
        }
        if let focusedWindow = value(appRoot, kAXFocusedWindowAttribute), string(focusedWindow as! AXUIElement, kAXTitleAttribute) != observedWindow {
            throw RelayError.message("The active window changed. Observe again before acting.")
        }
        if let target = action.target {
            guard let node = nodes[target], string(node.element, kAXRoleAttribute) == node.role else { throw RelayError.message("The target changed. Read the screen again.") }
            let currentLabel = Array(Set([string(node.element, kAXTitleAttribute), string(node.element, kAXDescriptionAttribute), string(node.element, kAXValueAttribute)].filter { !$0.isEmpty })).sorted().joined(separator: " | ")
            guard String(currentLabel.prefix(650)) == node.label else { throw RelayError.message("The target contents changed while planning. Read the screen again.") }
        }
        switch action.kind {
        case .focus:
            guard let node = nodes[action.target!], [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(node.role), string(node.element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { throw RelayError.message("Target is not an ordinary editable field.") }
            guard AXUIElementSetAttributeValue(node.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { throw RelayError.message("Could not focus that field. Try another control.") }
        case .click:
            if let id = action.target {
                guard let node = nodes[id] else { throw RelayError.message("Element ID is stale.") }
                guard AXUIElementPerformAction(node.element, kAXPressAction as CFString) == .success else { throw RelayError.message("Element has no press action. Use a different semantic target or request a coordinate click.") }
            } else {
                guard screenshots, !captureFrame.isEmpty else { throw RelayError.message("Coordinate clicking requires a current screenshot.") }
                let point = CGPoint(x: captureFrame.minX + action.x! * captureFrame.width, y: captureFrame.minY + action.y! * captureFrame.height)
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
        case .setValue:
            guard let node = nodes[action.target!], [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(node.role) else { throw RelayError.message("Target is not an editable text field.") }
            guard string(node.element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { throw RelayError.message("Secure field requires user input.") }
            _ = AXUIElementSetAttributeValue(node.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            guard AXUIElementSetAttributeValue(node.element, kAXValueAttribute as CFString, action.text! as CFString) == .success else { throw RelayError.message("This field cannot be set directly. Focus it and use typeText.") }
        case .typeText:
            if let id = action.target {
                guard let node = nodes[id], [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(node.role), string(node.element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { throw RelayError.message("Target is not an ordinary editable field.") }
                guard AXUIElementSetAttributeValue(node.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { throw RelayError.message("Could not focus the requested text field.") }
            }
            guard let focused = value(appRoot, kAXFocusedUIElementAttribute) else { throw RelayError.message("No focused text field.") }
            let role = string(focused as! AXUIElement, kAXRoleAttribute)
            guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else { throw RelayError.message("Focus an editable field before typing.") }
            let originalFocus = focused as! AXUIElement
            let chunks = TextChunks.unicode(action.text!)
            for chunk in chunks {
                try Task.checkCancellation()
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == observedPID,
                      let currentFocus = value(appRoot, kAXFocusedUIElementAttribute), CFEqual(currentFocus, originalFocus) else { throw RelayError.message("Typing stopped because focus changed.") }
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                RelayKeyboardEvent.post(down)
                RelayKeyboardEvent.post(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
                try await Task.sleep(nanoseconds: 3_000_000)
            }
        case .copySelection:
            clipboardBaseline = NSPasteboard.general.changeCount
            try sendKey("cmd+c") // Observe only the change counter, never clipboard contents.
        case .key: try sendKey(action.text!)
        case .scroll:
            let amount = Int32(min(1200, max(1, action.amount ?? 450)))
            let direction = action.text!
            let vertical = direction == "up" ? amount : direction == "down" ? -amount : 0
            let horizontal = direction == "left" ? amount : direction == "right" ? -amount : 0
            let windowBounds = value(appRoot, kAXFocusedWindowAttribute).flatMap { frame($0 as! AXUIElement) }
            guard let bounds = windowBounds else { throw RelayError.message("No focused window for scrolling.") }
            let point = CGPoint(x: bounds.midX, y: bounds.midY)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)
            event?.location = point; event?.post(tap: .cghidEventTap)
        default: throw RelayError.message("Action does not belong in the computer executor.")
        }
        return "\(action.kind.rawValue) issued. The next observation must verify its effect."
    }
    private func sendKey(_ chord: String) throws {
        let parts = chord.lowercased().split(separator: "+").map(String.init)
        guard let name = parts.last else { throw RelayError.message("Empty key chord.") }
        let keys: [String: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"return":36,"enter":36,"l":37,"j":38,"k":40,"n":45,"m":46,"tab":48,"space":49,"delete":51,"escape":53,"left":123,"right":124,"down":125,"up":126]
        guard let key = keys[name] else { throw RelayError.message("Unsupported key: \(name)") }
        var flags: CGEventFlags = []
        for modifier in parts.dropLast() {
            switch modifier { case "cmd", "command": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); case "alt", "option": flags.insert(.maskAlternate); case "ctrl", "control": flags.insert(.maskControl); default: throw RelayError.message("Unknown modifier.") }
        }
        // Block shortcuts into OS launchers, consoles, force-quit, and destructive deletion.
        if (name == "space" && flags.contains(.maskCommand)) || (name == "escape" && flags.contains(.maskAlternate)) || (name == "j" && flags.contains(.maskAlternate) && flags.contains(.maskCommand)) || (name == "delete" && flags.contains(.maskCommand)) { throw RelayError.message("This shortcut requires user control.") }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true); down?.flags = flags; RelayKeyboardEvent.post(down)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false); up?.flags = flags; RelayKeyboardEvent.post(up)
    }
}
