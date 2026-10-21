import Foundation
import RelayCore

@MainActor enum VoiceChecks {
    static func run() async throws {
        // 1. Natural disfluencies and app aliases, from the requested workflow.
        let chrome = SpeechIntent.normalized("hey open chrome and op open chrome open youtube play this video")
        checkEqual(chrome, "open Chrome open youtube play this video")
        checkEqual(SpeechIntent.normalized("hey open um open chat gpt app and write on this thread that I wanna write about it"), "open ChatGPT app and write on this thread that I wanna write about it")
        // 2. Dictation is literal, including filler words and command-looking phrases.
        checkEqual(SpeechIntent.dictation("open ChatGPT and write on this thread that I wanna write about it"), "I wanna write about it")
        checkEqual(SpeechIntent.dictation("dictate um I think Relay stop is the phrase"), "um I think Relay stop is the phrase")
        checkEqual(SpeechIntent.dictation("type hello and goodbye then click Save"), "hello and goodbye")
        checkEqual(SpeechIntent.normalized("open um Notes then type um do not change chat gpt"), "open Notes then type um do not change chat gpt")
        // 3. Voice controls require an entire control utterance, never text inside dictation.
        checkEqual(SpeechIntent.control("Hey Relay approve this action"), .approve)
        checkEqual(SpeechIntent.control("Relay stop listening"), .sleep)
        checkEqual(SpeechIntent.control("Relay stop now"), .stop)
        checkEqual(SpeechIntent.control("type Relay stop"), nil)
        checkEqual(SpeechIntent.control("Relay approve this action actually no"), nil)
        checkEqual(SpeechIntent.control("yes"), nil)
        // 4. Standby speech never becomes a task without a wake phrase.
        var gate = UtteranceGate()
        gate.update("open Chrome and delete a file", at: 0, requireWake: true)
        checkFalse(gate.active)
        checkFalse(gate.ready(at: 100))
        gate.update("background talk hey open Chrome", at: 1, requireWake: true)
        checkTrue(gate.active)
        checkEqual(gate.text, "open Chrome")
        checkTrue(gate.ready(at: 2.2))
        // 5. Speech energy prevents a stale transcript from being submitted mid-speech.
        gate.heardAudio(at: 2.15)
        checkFalse(gate.ready(at: 2.3))
        checkTrue(gate.ready(at: 3.4))
        // 6. Incomplete phrases get a longer pause, and revisions reset endpointing.
        gate.reset()
        gate.update("Hey Relay open Chrome and then", at: 0, requireWake: true)
        checkFalse(gate.ready(at: 1.8))
        gate.update("Hey Relay open Chrome and then open YouTube", at: 2, requireWake: true)
        checkFalse(gate.ready(at: 2.8))
        checkTrue(gate.ready(at: 3.2))
        // 7. Retraction of a proposed instruction replaces, rather than concatenates, it.
        gate.reset()
        gate.update("Hey Relay open Chrome", at: 0, requireWake: true)
        gate.update("Hey Relay don't open Chrome open Notes", at: 0.7, requireWake: true)
        checkEqual(gate.text, "don't open Chrome open Notes")
        checkFalse(gate.ready(at: 1.5))
        gate.update("regular conversation without a wake word", at: 0.8, requireWake: true)
        checkFalse(gate.active)
        checkFalse(gate.ready(at: 5))
        // 8. The requested browser is preserved across app → website workflows.
        let web = SpeechIntent.webCandidates("hey open Chrome then open YouTube")
        checkEqual(web.first?.action.application, "com.google.Chrome")
        checkEqual(web.first?.action.text, "https://www.youtube.com")
        checkTrue(SpeechIntent.webCandidates("open ChatGPT app").isEmpty)
        let search = SpeechIntent.webCandidates("open Chrome then search YouTube for Norbert Wiener then play the matching video")
        checkTrue(search.contains { $0.action.text?.contains("search_query=Norbert%20Wiener") == true })
        // 9. Exact text and editable target can be selected together in a single action.
        let obs = Observation(application: "ChatGPT", tree: "Message ChatGPT", labels: [4: "Message ChatGPT"], candidates: [ActionCandidate("Message ChatGPT", Action(kind: .focus, target: 4))])
        let choices = JevPlanner.candidates(task: "write on this thread that I wanna write about it", observation: obs)
        checkTrue(choices.values.contains { $0.action.kind == .typeText && $0.action.target == 4 && $0.action.text == "I wanna write about it" })
        // 10. Fast navigation never includes typing, Return, Save, or clicks.
        checkTrue(JevPlanner.isLocalNavigation(Action(kind: .focus, target: 4)))
        for action in [Action(kind: .key, text: "return"), Action(kind: .key, text: "cmd+s"), Action(kind: .typeText, text: "hello"), Action(kind: .click, target: 4)] { checkFalse(JevPlanner.isLocalNavigation(action)) }
        let api = FakeJev(); api.selected = "c3"
        let decision = try await JevPlanner(client: api).next(task: "Focus next field", memory: "", history: [], observation: obs)
        checkEqual(decision.action.kind, .key)
        checkEqual(api.states.count, 1)
        // 11. Unicode bursts are lossless and cannot split a surrogate pair.
        let original = String(repeating: "Hello 👩🏽‍💻 café မြန်မာ\n", count: 100)
        let chunks = TextChunks.unicode(original)
        checkEqual(String(decoding: chunks.flatMap { $0 }, as: UTF16.self), original)
        checkTrue(chunks.allSatisfy { $0.count <= 20 && !($0.first.map { (0xDC00...0xDFFF).contains($0) } ?? false) && !($0.last.map { (0xD800...0xDBFF).contains($0) } ?? false) })
        checkTrue(chunks.count < original.unicodeScalars.count / 5)
        // 12. Unsupported app routing and initial-context loss are rejected/avoided.
        checkThrows(try Action(kind: .openURL, text: "https://youtube.com", application: "com.apple.Terminal").validate())
        let engine = RunEngine(task: "this video", planner: FakePlanner([Decision(summary: "Question", action: Action(kind: .askUser, text: "Which video?"))]), computer: FakeComputer(), initialContext: "Selected video: a public demo")
        checkEqual(engine.record.events.first?.title, "Initial speech context")
        checkTrue(engine.record.events.first?.detail.contains("public demo") == true)
        // 13. Local command processing is measured independently of API/ASR latency.
        let began = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { _ = SpeechIntent.normalized("Hey open um open chat gpt app and write on this thread that hello") }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - began) * 1000 / 1000
        print(String(format: "Measured local normalization: %.3f ms per instruction (1,000 iterations; excludes speech, API and app latency)", milliseconds))
    }
}
