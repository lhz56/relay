import Foundation
import RelayCore

@MainActor private final class StreamingComputer: Computer {
    var actions: [Action] = []
    var bundle = "com.apple.finder"
    var url = ""
    func observe() async throws -> Observation {
        Observation(application: "Streaming fixture", tree: "", controls: url.isEmpty ? [] : [ObservedControl(id: 1, role: "AXTextField", caption: "Address", value: url, editable: true)], bundleID: bundle)
    }
    func execute(_ action: Action, observation: Observation) async throws -> String {
        actions.append(action)
        if action.kind == .openApp { bundle = action.text! }
        if action.kind == .openURL { url = action.text! }
        return "Executed"
    }
}

@MainActor enum LiveVoiceChecks {
    static func listening() -> LiveVoiceGate {
        var gate = LiveVoiceGate(); checkTrue(gate.arm(pause: 0.8)); gate.captureStarted(); return gate
    }
    static func run() async throws {
        // 1. A stable navigation clause runs while the following instruction is still being spoken.
        var gate = listening()
        gate.update("open Chrome then open YouTube", at: 0)
        gate.heardAudio(at: 0)
        checkEqual(gate.takeReady(at: 0), nil)
        gate.update("open Chrome then open YouTube and search", at: 0.2)
        gate.heardAudio(at: 0.5)
        checkEqual(gate.takeReady(at: 0.5), "open Chrome")
        checkEqual(gate.phase, .listening)
        // 2. Repeated hypotheses do not issue the same command again.
        gate.update("open Chrome then open YouTube and search", at: 0.6)
        checkEqual(gate.takeReady(at: 0.6), nil)
        checkEqual(gate.takeReady(at: 1.1), "open YouTube")
        checkEqual(gate.takeReady(at: 5), nil) // unfinished "search"
        // 3. A brief pause commits complete speech, but ongoing audio prevents tail submission.
        gate = listening(); gate.update("open Notes", at: 0); gate.heardAudio(at: 1)
        checkEqual(gate.takeReady(at: 1.5), nil)
        checkEqual(gate.takeReady(at: 1.9), "open Notes")
        checkEqual(gate.phase, .listening)
        // 4. Release flushes every remaining complete clause once, including a multistep tail.
        gate = listening(); gate.update("open Chrome and open YouTube", at: 0)
        checkTrue(gate.beginFinishing()); checkFalse(gate.beginFinishing())
        checkEqual(gate.takeReady(at: 0.1, final: true), "open Chrome")
        checkEqual(gate.takeReady(at: 0.1, final: true), "open YouTube")
        checkEqual(gate.takeReady(at: 0.1, final: true), nil)
        // 5. Release/cancel during microphone permission startup cannot arm a late callback.
        gate.cancel(); checkTrue(gate.arm(pause: 0.8)); gate.cancel(); gate.captureStarted()
        gate.update("open Notes", at: 3)
        checkEqual(gate.takeReady(at: 4, final: true), nil); checkEqual(gate.phase, .idle)
        // 6. A correction before commitment resets stability; the old app is never issued.
        gate = listening(); gate.update("open Chrome then open YouTube", at: 0)
        checkEqual(gate.takeReady(at: 0), nil)
        gate.update("open Safari then open YouTube", at: 0.3)
        checkEqual(gate.takeReady(at: 0.5), nil)
        checkEqual(gate.takeReady(at: 1), "open Safari")
        // 7. A material revision after commitment blocks further automatic work.
        gate.update("open Chrome then open YouTube", at: 1.1)
        checkTrue(gate.revisedCommittedSpeech)
        checkEqual(gate.takeReady(at: 3, final: true), nil)
        // 8. Punctuation/case changes are not treated as repeated commands or corrections.
        gate = listening(); gate.update("Open Chrome", at: 0)
        checkEqual(gate.takeReady(at: 1), "Open Chrome")
        gate.update("open Chrome. Then open YouTube", at: 2)
        checkFalse(gate.revisedCommittedSpeech)
        checkEqual(gate.takeReady(at: 3), "open YouTube")
        // 9. Recognition segment rotation preserves an unfinished clause without replaying accepted work.
        gate = listening(); gate.update("open Chrome and then", at: 0)
        checkEqual(gate.takeReady(at: 3, final: true), nil)
        gate.nextSegment(); gate.update("open YouTube", at: 4)
        checkEqual(gate.takeReady(at: 5, final: true), "open Chrome")
        checkEqual(gate.takeReady(at: 5, final: true), "open YouTube")
        gate.nextSegment(); gate.update("open Notes", at: 6)
        checkEqual(gate.takeReady(at: 7), "open Notes")
        // 10. Dictation containing app/command words is kept literal, not broken into actions.
        gate = listening(); gate.update("write on this thread that we should open Chrome and search for ideas", at: 0)
        gate.heardAudio(at: 0.5)
        checkEqual(gate.takeReady(at: 0.7), nil)
        checkEqual(gate.takeReady(at: 1.5), "write on this thread that we should open Chrome and search for ideas")
        // 11. Stop/pause/approval controls remain recognizable while an executor is busy.
        gate = listening(); gate.update("pause", at: 0)
        checkEqual(gate.takeReady(at: 1).flatMap(SpeechIntent.control), .pause)
        gate.nextSegment(); gate.update("stop", at: 2)
        checkEqual(gate.takeReady(at: 3).flatMap(SpeechIntent.control), .stop)
        // 12. Queued work never runs over a running, paused, asking, failed, or approval-blocked task.
        var queue = VoiceWorkQueue(); queue.append("open YouTube")
        for status in [RunStatus.running, .paused, .waiting, .approval, .failed] { checkEqual(queue.next(after: status), nil) }
        checkEqual(queue.next(after: .completed), "open YouTube")
        // 13. Release ends capture without discarding accepted instructions; Stop clears them.
        gate = listening(); queue.append("open Notes"); gate.cancel()
        checkEqual(queue.commands, ["open YouTube", "open Notes"])
        queue.didStart(); checkEqual(queue.next(after: .completed), "open Notes")
        queue.cancel(); checkEqual(queue.next(after: .completed), nil)
        // 14. The actual executor starts before capture ends; later speech runs sequentially with zero Jev calls.
        gate = listening(); queue = VoiceWorkQueue()
        let computer = StreamingComputer(); let api = PrivateTestJev()
        gate.update("open Chrome then open YouTube", at: 0)
        _ = gate.takeReady(at: 0)
        queue.append(gate.takeReady(at: 0.5)!)
        let first = RunEngine(task: queue.next(after: nil)!, planner: RestrictedJevPlanner(client: api), computer: computer)
        queue.didStart(); first.start()
        checkEqual(gate.phase, .listening)
        queue.append(gate.takeReady(at: 1)!)
        checkEqual(queue.next(after: first.record.status), nil)
        try await RelayCoreTests().waitUntil { first.record.status == .completed }
        checkEqual(computer.actions.map(\.kind), [.openApp])
        let second = RunEngine(task: queue.next(after: first.record.status)!, planner: RestrictedJevPlanner(client: api), computer: computer)
        queue.didStart(); checkTrue(gate.beginFinishing()); gate.cancel(); second.start()
        try await RelayCoreTests().waitUntil { second.record.status == .completed }
        checkEqual(computer.actions.map(\.kind), [.openApp, .openURL]); checkTrue(api.requests.isEmpty)
        checkTrue(queue.commands.isEmpty)
        // 15. Disfluencies preserve a full sequence without a wake phrase.
        gate = listening(); gate.update("hey open chrome and op open chrome open youtube", at: 0)
        var accepted: [String] = []
        while let next = gate.takeReady(at: 1, final: true) { accepted.append(next) }
        checkFalse(accepted.isEmpty); checkTrue(accepted.allSatisfy { DirectWorkflow($0) != nil })
        // 17. Alias/tokenization changes to an accepted navigation command do not stop or replay it.
        gate = listening(); gate.update("open You Tube", at: 0)
        checkEqual(gate.takeReady(at: 1), "open YouTube")
        gate.update("open YouTube then open Notes", at: 2)
        checkFalse(gate.revisedCommittedSpeech)
        checkEqual(gate.takeReady(at: 3), "open Notes")
        // 18. A transient ASR revision stalls new work, then recovers if its committed prefix returns.
        gate = listening(); gate.update("open Chrome", at: 0)
        _ = gate.takeReady(at: 1)
        gate.update("open", at: 2)
        checkTrue(gate.revisedCommittedSpeech); checkFalse(gate.revisionNeedsPause(at: 2.2))
        checkEqual(gate.takeReady(at: 3), nil)
        gate.update("open Chrome then open YouTube", at: 2.3)
        checkFalse(gate.revisedCommittedSpeech)
        checkEqual(gate.takeReady(at: 3.2), "open YouTube")
        // 19. A stable material revision or final changed transcript still requires a pause.
        gate.update("open Safari then open YouTube", at: 4)
        checkFalse(gate.revisionNeedsPause(at: 4.2))
        checkTrue(gate.revisionNeedsPause(at: 5))
        checkTrue(gate.revisionNeedsPause(at: 4.2, final: true))
        // 20. An isolated partial word cannot start work before the recognizer finishes its phrase.
        gate = listening(); gate.update("Enter", at: 0)
        checkEqual(gate.takeReady(at: 2), nil)
        gate.update("open Chrome", at: 3)
        checkEqual(gate.takeReady(at: 4), "open Chrome")
        // 16. An unfinished final tail is retained for an honest message, never fabricated into an action.
        gate = listening(); gate.update("open", at: 0); checkTrue(gate.beginFinishing())
        checkEqual(gate.takeReady(at: 5, final: true), nil); checkEqual(gate.pendingText, "open")
    }
}
