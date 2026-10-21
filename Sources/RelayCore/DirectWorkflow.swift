import Foundation

/// Only a fully parsed, explicit command can use this path. Unknown steps use Jev.
public struct DirectWorkflow {
    public let steps: [ActionCandidate]
    public init?(_ task: String) {
        guard !task.contains("\nUser follow-up: "), task.count <= 4000 else { return nil }
        var rest = SpeechIntent.normalized(task).trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [ActionCandidate] = []
        var browser: String?
        let apps = [("Google Chrome", "com.google.Chrome"), ("Chrome", "com.google.Chrome"),
            ("Safari", "com.apple.Safari"), ("Arc", "company.thebrowser.Browser"),
            ("ChatGPT", "com.openai.chat"), ("Notes", "com.apple.Notes"),
            ("Claude", "com.anthropic.claudefordesktop"),
            ("TextEdit", "com.apple.TextEdit"), ("Finder", "com.apple.finder")]
        func prefix(_ pattern: String, _ text: String) -> (String, String)? {
            guard let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")", options: [.caseInsensitive]),
                  let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text) else { return nil }
            return (String(text[range]), String(text[range.upperBound...]))
        }
        while !rest.isEmpty, result.count < 12 {
            var parsed: ActionCandidate?
            if let part = prefix(#"(?:open|launch|start|go to|visit)\s+(?:the\s+)?"#, rest) {
                let target = part.1
                // App names precede sites: "Google Chrome" never means Google Search.
                for (name, id) in apps {
                    if let found = prefix(NSRegularExpression.escapedPattern(for: name) + #"(?:\s+app)?(?=$|[\s,.!])"#, target) {
                        parsed = ActionCandidate("Open " + name, Action(kind: .openApp, text: id)); rest = found.1
                        if ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"].contains(id) { browser = id }
                        break
                    }
                }
                if parsed == nil {
                    for (name, url) in [("YouTube", "https://www.youtube.com/"), ("Google", "https://www.google.com/"), ("Twitter", "https://x.com/"), ("X", "https://x.com/")] {
                        if let found = prefix(name + #"(?=$|[\s,.!])"#, target) {
                            parsed = ActionCandidate("Open " + name, Action(kind: .openURL, text: url, application: browser))
                            rest = found.1; break
                        }
                    }
                }
                if parsed == nil, let found = prefix(#"https?://[^\s<>\"\x60]+"#, target) {
                    let url = found.0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)"))
                    let action = Action(kind: .openURL, text: url, application: browser)
                    guard (try? action.validate()) != nil else { return nil }
                    parsed = ActionCandidate("Open requested website", action); rest = found.1
                }
            } else if let found = prefix(#"copy\s+(?:(?:the|my|this)\s+)?(?:(?:current|selected)\s+)?(?:selection|text)(?=$|[,;.!]|\s+(?:and|then)\b)"#, rest) {
                parsed = ActionCandidate("Copy the current selection", Action(kind: .copySelection)); rest = found.1
            } else if let found = prefix(#"(?:type|dictate|write\s+(?:on|in)\s+(?:this|the|current)\s+(?:thread|chat|document)\s+that)\s+"#, rest) {
                var text = found.1
                if let range = text.range(of: #"\s+(?:and\s+)?then\s+verify\s+(?:the\s+text|it)\s+is\s+there[.!]?$"#, options: [.regularExpression, .caseInsensitive]) { text = String(text[..<range.lowerBound]) }
                if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("“") && text.hasSuffix("”")) { text = String(text.dropFirst().dropLast()) }
                guard !text.isEmpty else { return nil }
                if text.range(of: #"\b(?:then|and then)\s+(?:open|click|send|delete|press|save|submit|search)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
                parsed = ActionCandidate("Type your dictated text", Action(kind: .typeText, text: text)); rest = ""
            }
            guard let parsed else { return nil }
            result.append(parsed)
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.isEmpty || [".", "!"].contains(rest) { rest = ""; break }
            if let verification = prefix(#"[,;]?\s*(?:(?:and\s+)?then\s+|and\s+)?(?:verify|check)\s+(?:it|Google Chrome|Chrome|YouTube|Google|ChatGPT|Notes|Safari|Arc|TextEdit|Finder)\s+is\s+open[.!]?$"#, rest), verification.1.isEmpty {
                let lower = rest.lowercased()
                let lastName = parsed.label.replacingOccurrences(of: "Open ", with: "").lowercased()
                if lower.contains("it is open") || lower.contains(lastName + " is open") ||
                    (parsed.action.kind == .openURL && parsed.action.text?.contains("youtube.com") == true && lower.contains("youtube is open")) {
                    rest = ""; break
                }
                return nil
            }
            if let separator = prefix(#"(?:[,;]\s*)?(?:(?:and\s+)?then\s+|and\s+)"#, rest) { rest = separator.1 }
            else if rest.hasPrefix(",") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
            else if prefix(#"(?:open|launch|visit|go to)\s+"#, rest) == nil { return nil }
        }
        guard rest.isEmpty, !result.isEmpty else { return nil }
        steps = result
    }
    public func next(after attempts: [Action], observation: Observation) -> Decision? {
        let executed = attempts.filter { ![.wait, .observe].contains($0.kind) }
        guard executed.count <= steps.count else { return nil }
        for (action, step) in zip(executed, steps) {
            guard action.kind == step.action.kind, action.text == step.action.text, action.application == step.action.application else { return nil }
        }
        let count = executed.count, plan = steps.map(\.label)
        if count > 0, !verified(steps[count - 1].action, in: observation) {
            let waits = attempts.reversed().prefix { [.wait, .observe].contains($0.kind) }.count
            if waits >= 2 {
                return Decision(summary: "The last step could not be verified.", plan: plan, completedSteps: count - 1, action: Action(kind: .askUser, text: "I could not verify the last step in the app. Check the result before continuing."))
            }
            return Decision(summary: "Waiting for the result", plan: plan, completedSteps: count - 1, action: Action(kind: .wait, amount: 600 + waits * 200))
        }
        if count == steps.count {
            return Decision(summary: "Done", plan: plan, completedSteps: count, evidence: "Each requested step was verified in the target app.", action: Action(kind: .finish))
        }
        var action = steps[count].action
        if action.kind == .typeText {
            let fields = observation.controls.filter { $0.editable && !Self.isAddress($0) }
            let composers = fields.filter { ["message", "message chatgpt", "ask anything", "ask chatgpt", "message claude", "reply to claude", "how can i help you today?", "body"].contains($0.caption.lowercased()) }
            let focused = fields.filter(\.focused)
            guard let field = composers.count == 1 ? composers.first : focused.count == 1 ? focused.first : nil else { return nil }
            action.target = field.id
        }
        return Decision(summary: steps[count].label, plan: plan, completedSteps: count, action: action)
    }
    private func verified(_ action: Action, in observation: Observation) -> Bool {
        switch action.kind {
        case .openApp: return observation.bundleID == action.text
        case .openURL:
            guard action.application == nil || action.application == observation.bundleID, let url = action.text else { return false }
            return observation.controls.contains { Self.isAddress($0) && !$0.focused && (Self.sameURL($0.value, url) || (url == "https://x.com/" && Self.sameURL($0.value, "https://x.com/home"))) }
        case .typeText:
            guard let text = action.text else { return false }
            return observation.controls.contains { $0.editable && !Self.isAddress($0) && $0.value.contains(text) }
        case .copySelection: return observation.selectionCopied
        default: return false
        }
    }
    public static func isAddress(_ field: ObservedControl) -> Bool {
        field.editable && ["address and search bar", "address", "search or enter website name", "search or enter address"].contains(field.caption.lowercased())
    }
    public static func sameURL(_ displayed: String, _ expected: String) -> Bool {
        let display = displayed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty, !display.contains(" "), let wanted = URLComponents(string: expected),
              let actual = URLComponents(string: display.contains("://") ? display : (wanted.scheme ?? "https") + "://" + display),
              actual.user == nil, actual.password == nil else { return false }
        func host(_ value: String?) -> String {
            let lower = (value ?? "").lowercased()
            return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        }
        return actual.scheme?.lowercased() == wanted.scheme?.lowercased() && !host(actual.host).isEmpty &&
            host(actual.host) == host(wanted.host) && actual.port == wanted.port &&
            (actual.percentEncodedPath.isEmpty ? "/" : actual.percentEncodedPath) == (wanted.percentEncodedPath.isEmpty ? "/" : wanted.percentEncodedPath) &&
            actual.percentEncodedQuery == wanted.percentEncodedQuery && actual.percentEncodedFragment == wanted.percentEncodedFragment
    }
}
