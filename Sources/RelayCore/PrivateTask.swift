import Foundation

/// A per-run vault. Original payloads and URL arguments never enter the request object.
public struct PrivateTask {
    public private(set) var instruction: String
    public private(set) var values: [String] = []
    public private(set) var dictations: [String] = []
    public private(set) var urls: [ActionCandidate] = []
    public let original: String

    public init(_ task: String) {
        original = task; instruction = task
        // Process follow-ups independently so the dictation regex cannot swallow a later instruction.
        for line in task.components(separatedBy: "\nUser follow-up: ") {
            for value in JevPlanner.textCandidates(line) where !value.isEmpty {
                if !dictations.contains(value) { dictations.append(value) }
                add(value)
            }
        }
        urls = SpeechIntent.webCandidates(task)
        if let re = try? NSRegularExpression(pattern: #"https?://[^\s<>\"`]+"#) {
            for match in re.matches(in: task, range: NSRange(task.startIndex..., in: task)) {
                guard let range = Range(match.range, in: task) else { continue }
                let url = String(task[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
                let action = Action(kind: .openURL, text: url, application: SpeechIntent.browser(task))
                if (try? action.validate()) != nil { urls.append(ActionCandidate("Open requested web address", action)); add(url) }
            }
        }
        var uniqueURLs: [ActionCandidate] = []
        for candidate in urls {
            if !uniqueURLs.contains(where: { existing in
                existing.action.application == candidate.action.application &&
                DirectWorkflow.sameURL(existing.action.text ?? "", candidate.action.text ?? "")
            }) { uniqueURLs.append(candidate) }
        }
        urls = uniqueURLs
        for candidate in urls {
            if let url = candidate.action.text, let components = URLComponents(string: url) {
                for item in components.queryItems ?? [] { if let value = item.value { add(value) } }
            }
        }
        instruction = redact(task)
    }
    private mutating func add(_ value: String) { if !values.contains(value) { values.append(value) } }
    public func reference(_ value: String) -> String {
        if let index = values.firstIndex(of: value) { return "local_text_\(index + 1)" }
        return "local_argument"
    }
    public func redact(_ text: String) -> String {
        let output = NSMutableString(string: text)
        // Replace ranges in the original text, never inside a previously inserted reference.
        let pattern = values.sorted(by: { $0.count > $1.count }).map(NSRegularExpression.escapedPattern).joined(separator: "|")
        if !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                let found = (text as NSString).substring(with: match.range)
                if let value = values.first(where: { $0.caseInsensitiveCompare(found) == .orderedSame }) {
                    output.replaceCharacters(in: match.range, with: "[\(reference(value))]")
                }
            }
        }
        var result = output as String
        for pattern in [#"https?://[^\s<>]+"#, #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, #"\b(?:sk|key|token)[-_][A-Z0-9_-]{8,}\b"#, #"\b\d[\d ()+.-]{6,}\d\b"#] {
            result = result.replacingOccurrences(of: pattern, with: "[private detail]", options: [.regularExpression, .caseInsensitive])
        }
        return String(result.prefix(4000))
    }
    public static let commonControls: Set<String> = [
        "new", "new note", "new chat", "new document", "compose", "search", "search youtube", "search google",
        "address and search bar", "address", "search or enter website name", "message", "message chatgpt", "ask anything", "ask chatgpt", "prompt", "title", "body",
        "play", "pause", "play video", "stop", "next", "previous", "back", "forward", "home", "close", "cancel", "done", "ok", "save", "save as", "edit", "file", "view",
        "send", "send message", "submit", "publish", "delete", "delete note", "move to trash", "trash", "remove", "buy now", "purchase", "pay", "pay now", "checkout", "allow", "grant", "install", "accept", "sign in", "log in",
        "create", "create note", "create a note", "new tab", "refresh", "reload", "mute", "unmute", "fullscreen"
    ]
    public func controlName(_ control: ObservedControl) -> String? {
        let name = control.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        // Exact local payload matches may identify a named result without disclosing its title.
        if let match = values.first(where: { !$0.isEmpty && name.range(of: "(?<!\\w)" + NSRegularExpression.escapedPattern(for: $0) + "(?!\\w)", options: [.regularExpression, .caseInsensitive]) != nil }) {
            return "control matching \(reference(match))"
        }
        let ordinary = name.lowercased().replacingOccurrences(of: #"\s*\([a-z⌘⇧⌥↵^ ]{1,12}\)$"#, with: "", options: .regularExpression)
        if Self.commonControls.contains(ordinary) { return ordinary }
        if control.editable { return control.focused ? "focused editable field" : "editable field" }
        return nil // Document text, chat titles, tab titles, menus of recent files, etc. stay local.
    }
    public var needsPrivateHandoff: Bool {
        instruction.range(of: #"\b(password|passcode|credential|banking|bank account|credit card|social security|medical record|security settings|captcha)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
