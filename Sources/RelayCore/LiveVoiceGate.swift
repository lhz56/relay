import Foundation

/// Consumes cumulative ASR hypotheses, not individual recognition callbacks.
/// A stable, explicit navigation clause can run while its following clause is spoken.
public struct LiveVoiceGate {
    public enum Phase { case idle, preparing, listening, finishing }
    public private(set) var phase: Phase = .idle
    public private(set) var transcript = ""
    public private(set) var revisedCommittedSpeech = false
    public var pauseSeconds: TimeInterval = 0.8
    public var literal = false
    private var committed: [String] = []
    private var committedText = ""
    private var revisionStarted: TimeInterval?
    private var carry = ""
    private var lastChange: TimeInterval = 0
    private var lastAudio: TimeInterval = 0
    private var candidateText = ""
    private var candidateSince: TimeInterval = 0

    public init() {}
    public mutating func arm(pause: TimeInterval) -> Bool {
        guard phase == .idle else { return false }
        self = Self(); pauseSeconds = min(2.5, max(0.6, pause)); phase = .preparing
        return true
    }
    public mutating func captureStarted() { if phase == .preparing { phase = .listening } }
    public mutating func beginFinishing() -> Bool {
        guard phase == .listening else { return false }
        phase = .finishing; return true
    }
    public mutating func cancel() { self = Self() }
    public mutating func heardAudio(at time: TimeInterval) { if phase == .listening { lastAudio = time } }
    public mutating func update(_ text: String, at time: TimeInterval) {
        guard phase == .listening || phase == .finishing else { return }
        let next = [carry, text].filter { !$0.isEmpty }.joined(separator: " ")
        if next != transcript { transcript = next; lastChange = time }
        let words = Self.words(next)
        var matches = words.count >= committed.count && Array(words.prefix(committed.count)).map(Self.key) == committed
        // Navigation aliases and ASR tokenization changes must not replay an action.
        // Never apply semantic matching to dictated content: its exact words matter.
        if !matches, let accepted = Self.navigation(committedText) {
            for end in 1...max(1, min(words.count, committed.count + 8)) {
                let prefix = words.prefix(end).joined(separator: " ")
                if Self.navigation(prefix) == accepted {
                    committed = words.prefix(end).map(Self.key); committedText = prefix; matches = true; break
                }
            }
        }
        revisedCommittedSpeech = !matches
        if matches { revisionStarted = nil }
        else if revisionStarted == nil { revisionStarted = time }
    }
    public func revisionNeedsPause(at time: TimeInterval, final: Bool = false) -> Bool {
        revisedCommittedSpeech && (final || time - (revisionStarted ?? time) >= max(0.8, pauseSeconds))
    }
    public var pendingText: String { Self.words(transcript).dropFirst(committed.count).joined(separator: " ") }
    public mutating func takeReady(at time: TimeInterval, final: Bool = false) -> String? {
        guard phase == .listening || phase == .finishing, !revisedCommittedSpeech else { return nil }
        let all = Self.words(transcript)
        var start = committed.count
        while !literal && start < all.count && ["and", "then"].contains(Self.key(all[start])) { start += 1 }
        guard start < all.count else { return nil }
        var end = all.count
        var navigationBoundary = false
        let verbs = ["open", "launch", "visit", "search", "play", "write", "type", "dictate", "click", "go"]
        if !literal && start + 1 < all.count {
            for index in (start + 1)..<all.count where verbs.contains(Self.key(all[index])) {
                var prefixEnd = index
                while prefixEnd > start && ["and", "then"].contains(Self.key(all[prefixEnd - 1])) { prefixEnd -= 1 }
                let prefix = all[start..<prefixEnd].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",; "))
                // Do not split words inside dictated prose or speculate on a partial search/query.
                if let direct = DirectWorkflow(prefix), direct.steps.allSatisfy({ [.openApp, .openURL].contains($0.action.kind) }) {
                    end = prefixEnd; navigationBoundary = true; break
                }
            }
        }
        let text = all[start..<end].joined(separator: " ").trimmingCharacters(in: literal ? .whitespacesAndNewlines : CharacterSet(charactersIn: ",; "))
        guard !text.isEmpty, literal || !SpeechIntent.incomplete(text) || SpeechIntent.control(text) != nil else { return nil }
        if text != candidateText { candidateText = text; candidateSince = time }
        if !final {
            // A lone provisional word such as "Enter" is not a complete instruction.
            guard literal || end - start > 1 || SpeechIntent.control(text) != nil else { return nil }
            if navigationBoundary {
                guard time - candidateSince >= 0.4 else { return nil }
            } else {
                // Never commit a still-growing tail merely because its first words look actionable.
                guard time - lastChange >= pauseSeconds, time - lastAudio >= pauseSeconds else { return nil }
            }
        }
        committed = Array(all.prefix(end)).map(Self.key)
        committedText = all.prefix(end).joined(separator: " ")
        candidateText = ""
        return literal ? text : SpeechIntent.normalized(text)
    }
    /// A recognizer segment ended, but the held microphone session may continue.
    public mutating func nextSegment() {
        carry = pendingText; transcript = carry; committed = []; committedText = ""; candidateText = ""
        revisedCommittedSpeech = false; revisionStarted = nil
    }
    private static func navigation(_ text: String) -> [String]? {
        guard let workflow = DirectWorkflow(text), workflow.steps.allSatisfy({ [.openApp, .openURL].contains($0.action.kind) }) else { return nil }
        return workflow.steps.map { $0.action.fingerprint }
    }
    private static func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    private static func key(_ text: String) -> String { text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
}

/// One executor at a time. Questions, approvals and failures keep later work queued.
public struct VoiceWorkQueue {
    public private(set) var commands: [String] = []
    public init() {}
    public mutating func append(_ text: String) { commands.append(text) }
    public func next(after status: RunStatus?) -> String? {
        guard status == nil || [.idle, .completed, .stopped].contains(status!) else { return nil }
        return commands.first
    }
    public mutating func didStart() { if !commands.isEmpty { commands.removeFirst() } }
    public mutating func cancel() { commands.removeAll() }
}
