import Foundation

public enum VoiceControl: String { case stop, pause, resume, approve, reject, sleep }

public enum SpeechIntent {
    /// Mode commands are explicit; all later dictated words stay literal and local.
    public static func dictationTarget(_ text: String) -> String? {
        let value = normalized(text).lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard let range = value.range(of: #"^(?:start|begin)\s+(?:dictating|transcribing|dictation)(?:\s+(?:in|into|to)\s+(?:the\s+)?(claude|chatgpt|current app))?$"#, options: .regularExpression) else { return nil }
        let command = String(value[range])
        if command.hasSuffix("claude") { return "Claude" }
        if command.hasSuffix("chatgpt") { return "ChatGPT app" }
        return "current"
    }
    private static func replace(_ text: String, _ pattern: String, _ replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }
    public static func wakeRange(_ text: String) -> Range<String.Index>? {
        text.range(of: #"\b(?:hey[ ,]+relay|relay[ ,]+|hey[ ,]+(?=(?:open|launch|go|search|play|write|type|dictate|stop|pause|resume)\b))"#, options: [.regularExpression, .caseInsensitive])
    }
    public static func removeWake(_ text: String) -> String {
        let stripped = replace(text, #"^\s*(?:hey[ ,]+relay[ ,]*|relay[ ,]+|hey[ ,]+)"#, "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func control(_ text: String) -> VoiceControl? {
        let value = removeWake(text).lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        switch value {
        case "stop", "stop now", "cancel", "cancel task": return .stop
        case "pause", "pause task", "wait": return .pause
        case "resume", "continue", "continue task": return .resume
        case "approve", "approve this action": return .approve
        case "reject", "don't do that", "do not do that": return .reject
        case "stop listening", "go to sleep", "sleep": return .sleep
        default: return nil
        }
    }
    /// Preserve the dictated payload. Cleanup applies only to the command before it.
    public static func normalized(_ original: String) -> String {
        let text = removeWake(original)
        let boundary = text.range(of: #"\b(?:type|dictate|write|title)\b"#, options: [.regularExpression, .caseInsensitive])?.lowerBound ?? text.endIndex
        var command = String(text[..<boundary])
        let payload = String(text[boundary...])
        command = replace(command, #"\b(?:um+|uh+|erm|hmm|op(?=\s+open))\b[, ]*"#, " ")
        command = replace(command, #"\b(?:open\s+){2,}"#, "open ")
        command = replace(command, #"\bchat\s+g\s*p\s*t\b"#, "ChatGPT")
        command = replace(command, #"\byou\s+tube\b"#, "YouTube")
        command = replace(command, #"\bopen\s+(?:google\s+)?chrome(?:\s+(?:and\s+)?open\s+(?:google\s+)?chrome)+\b"#, "open Chrome")
        command = replace(command, #"\s+"#, " ")
        return (command + payload).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func dictation(_ original: String) -> String? {
        let patterns = [
            #"(?i)\bwrite\s+(?:in|on)\s+(?:this|the|that|current)\s+(?:thread|chat|note|document)\s+(?:that|the following|saying)\s+(.+)"#,
            #"(?i)\b(?:type|dictate)\s+(?:the following\s*[:,-]?\s*)?(.+)"#,
            #"(?i)\b(?:title(?:\s+say|\s+to|\s+as)?|write)\s+(.+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]), let match = regex.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)), let range = Range(match.range(at: 1), in: original) else { continue }
            var text = String(original[range])
            // Only explicit workflow separators end dictation; an ordinary "and" stays literal.
            if let end = text.range(of: #"\s+(?:and\s+)?then\s+(?:send|submit|click|open|verify|check|press|go|play)\b|\s+end dictation\b"#, options: [.regularExpression, .caseInsensitive]) { text = String(text[..<end.lowerBound]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("“") && text.hasSuffix("”")) { text.removeFirst(); text.removeLast() }
            return text.isEmpty ? nil : text
        }
        return nil
    }
    public static func incomplete(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return value.range(of: #"\b(?:and|then|um|uh|open|type|write|about|for|to|the|a|in|on|that|search|play|actually|no|wait)$"#, options: .regularExpression) != nil
    }
    public static func browser(_ task: String) -> String? {
        let normalized = normalized(task)
        if normalized.range(of: #"\bchrome\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return "com.google.Chrome" }
        if normalized.range(of: #"\bsafari\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return "com.apple.Safari" }
        if normalized.range(of: #"\barc\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return "company.thebrowser.Browser" }
        return nil
    }
    public static func webCandidates(_ task: String) -> [ActionCandidate] {
        let text = normalized(task)
        var result: [ActionCandidate] = []
        let browser = browser(text)
        for (name, url) in [("YouTube", "https://www.youtube.com"), ("Google", "https://www.google.com"), ("ChatGPT", "https://chatgpt.com"), ("Twitter", "https://x.com"), ("X", "https://x.com")] {
            let pattern = #"\b(?:open|go to|visit)\s+(?:up\s+)?(?:the\s+)?"# + name + #"\b(?!\s+(?:app|Chrome)\b)"#
            if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                result.append(ActionCandidate("Open requested website \(name)\(browser == nil ? "" : " in the requested browser")", Action(kind: .openURL, text: url, application: browser)))
            }
        }
        let queryPattern = #"(?i)\b(?:search\s+(?:on\s+)?(?:youtube|google)\s+(?:for\s+)?|(?:youtube|google)\s+search\s+(?:for\s+)?)(.+?)(?=\s+(?:and\s+)?then\b|$)"#
        if let regex = try? NSRegularExpression(pattern: queryPattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) {
            let query = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"“” ."))
            let youtube = String(text[Range(match.range, in: text)!]).lowercased().contains("youtube")
            var url = URLComponents(string: youtube ? "https://www.youtube.com/results" : "https://www.google.com/search")!
            url.queryItems = [URLQueryItem(name: youtube ? "search_query" : "q", value: query)]
            if let url = url.url { result.append(ActionCandidate("Search \(youtube ? "YouTube" : "Google") for exact user query: \(query)", Action(kind: .openURL, text: url.absoluteString, application: browser))) }
        }
        return result
    }
}

/// Timestamp-driven endpointing. Silence is audio silence, not merely missing ASR updates.
public struct UtteranceGate {
    public private(set) var text = ""
    public private(set) var active = false
    private var wakeOffset: Int?
    private var lastChange: TimeInterval = 0
    private var lastSpeech: TimeInterval = 0
    public var pauseSeconds: TimeInterval = 1.15
    public init() {}
    public mutating func reset() { text = ""; active = false; wakeOffset = nil; lastChange = 0; lastSpeech = 0 }
    public mutating func heardAudio(at time: TimeInterval) { lastSpeech = time }
    public mutating func update(_ transcript: String, at time: TimeInterval, requireWake: Bool) {
        if requireWake {
            guard let range = SpeechIntent.wakeRange(transcript) else {
                if active { reset() }
                return
            }
            wakeOffset = transcript.distance(from: transcript.startIndex, to: range.lowerBound)
        } else { wakeOffset = 0 }
        if !active { active = true; lastSpeech = time }
        let offset = min(wakeOffset ?? 0, transcript.count)
        let next = SpeechIntent.removeWake(String(transcript.dropFirst(offset)))
        if next != text { text = next; lastChange = time }
    }
    public func ready(at time: TimeInterval) -> Bool {
        guard active, !text.isEmpty else { return false }
        let required = SpeechIntent.incomplete(text) ? max(2.7, pauseSeconds) : pauseSeconds
        return time - lastChange >= required && time - lastSpeech >= required
    }
}
