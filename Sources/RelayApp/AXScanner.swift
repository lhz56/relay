import ApplicationServices
import Foundation
import RelayCore

// AX elements are opaque cross-process references. The scan runs on one background
// task; its snapshot is handed to the main-actor executor only after that task ends.
struct AXNode: @unchecked Sendable {
    let element: AXUIElement
    let role: String
    let label: String
    let pressable: Bool
}
struct AXSnapshot: @unchecked Sendable {
    var nodes: [Int: AXNode] = [:]
    var lines: [String] = []
    var window = ""
    var controls: [ObservedControl] = []
}
enum AXScanner {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    static func text(_ element: AXUIElement, _ attribute: String) -> String { value(element, attribute) as? String ?? "" }
    static func read(pid: pid_t) -> AXSnapshot {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.08)
        let window = value(root, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        let focus = value(root, kAXFocusedUIElementAttribute)
        var result = AXSnapshot()
        result.window = window.map { text($0, kAXTitleAttribute) } ?? ""
        var visited = Set<CFHashCode>()
        let deadline = Date().addingTimeInterval(0.7)
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 18, result.nodes.count < 180, visited.count < 500, Date() < deadline, !Task.isCancelled else { return }
            guard visited.insert(CFHash(element)).inserted else { return }
            let role = text(element, kAXRoleAttribute)
            if text(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { result.lines.append("[secure field hidden]"); return }
            let label = Array(Set([text(element, kAXTitleAttribute), text(element, kAXDescriptionAttribute), text(element, kAXValueAttribute)].filter { !$0.isEmpty })).sorted().joined(separator: " | ")
            let editable = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
            if !label.isEmpty || editable || [kAXButtonRole, kAXCheckBoxRole, "AXLink"].contains(role) {
                var actions: CFArray?
                _ = AXUIElementCopyActionNames(element, &actions)
                let index = result.nodes.count
                result.nodes[index] = AXNode(element: element, role: role, label: String(label.prefix(650)), pressable: (actions as? [String] ?? []).contains(kAXPressAction))
                let caption = [text(element, kAXTitleAttribute), text(element, kAXDescriptionAttribute), text(element, kAXPlaceholderValueAttribute)].first { !$0.isEmpty } ?? ""
                result.controls.append(ObservedControl(id: index, role: role, caption: caption, value: String(text(element, kAXValueAttribute).prefix(12000)), focused: focus.map { CFEqual($0, element) } == true, editable: editable))
                result.lines.append("[\(index)] \(role)\(focus.map { CFEqual($0, element) } == true ? " FOCUSED" : "") \(label.prefix(650))")
                if let selected = value(element, kAXSelectedTextAttribute) as? String, !selected.isEmpty { result.lines.append("User-selected text: \(selected.prefix(1600))") }
            }
            for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1) }
        }
        walk(window ?? root, 0)
        if let menu = value(root, kAXMenuBarAttribute) { walk(menu as! AXUIElement, 0) }
        if Date() >= deadline { result.lines.append("[Partial accessibility snapshot: use another observation or OCR if the needed control is absent]") }
        return result
    }
}
