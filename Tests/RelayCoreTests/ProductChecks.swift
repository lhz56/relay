import Foundation
import RelayCore

@MainActor enum ProductChecks {
    static func run() async throws {
        // 1. Chrome then Twitter is a completely local ordered workflow.
        let social = DirectWorkflow("open Chrome then open Twitter")!
        checkEqual(social.steps.map(\.action.kind), [.openApp, .openURL])
        checkEqual(social.steps.last?.action.application, "com.google.Chrome")
        let socialResult = social.next(after: social.steps.map(\.action), observation: Observation(application: "Chrome", tree: "", controls: [ObservedControl(id: 1, role: "AXTextField", caption: "Address", value: "x.com/home", editable: true)], bundleID: "com.google.Chrome"))
        checkEqual(socialResult?.action.kind, .finish)
        // 2. Copy is issued once and completion requires a changed clipboard counter, never its contents.
        let copy = DirectWorkflow("copy the current selection")!
        let obs = Observation(application: "TextEdit", tree: "PRIVATE_SELECTION")
        let action = copy.next(after: [], observation: obs)!.action
        checkEqual(action.kind, .copySelection)
        checkEqual(copy.next(after: [action], observation: obs)?.action.kind, .wait)
        var copied = obs; copied.selectionCopied = true
        checkEqual(copy.next(after: [action], observation: copied)?.action.kind, .finish)
        // 3. Copy and Claude dictation stay out of the model transport on their direct paths.
        let api = PrivateTestJev(); let planner = RestrictedJevPlanner(client: api)
        let selected = try await planner.next(task: "copy selected text", memory: "", history: [], observation: obs)
        checkEqual(selected.action.kind, .copySelection); checkTrue(api.requests.isEmpty)
        let claude = DirectWorkflow("open Claude")!
        checkEqual(claude.steps.first?.action.text, "com.anthropic.claudefordesktop")
        // 4. Explicit dictation mode names a supported app or uses the current target.
        checkEqual(SpeechIntent.dictationTarget("start transcribing into Claude"), "Claude")
        checkEqual(SpeechIntent.dictationTarget("start dictating"), "current")
        checkEqual(SpeechIntent.dictationTarget("begin dictation in the current app"), "current")
        checkEqual(SpeechIntent.dictationTarget("do not start dictating"), nil)
        // 5. Mode dictation preserves wake words, fillers, punctuation and command-like words literally.
        var gate = LiveVoiceGate(); checkTrue(gate.arm(pause: 0.8)); gate.captureStarted(); gate.literal = true
        gate.update("hey um open Chrome and then", at: 0)
        checkEqual(gate.takeReady(at: 1), "hey um open Chrome and then")
        gate.nextSegment(); gate.update("and keep this comma,", at: 2)
        checkEqual(gate.takeReady(at: 3), "and keep this comma,")
        // 6. Separate literal chunks retain the space between sentences without pressing Send.
        let typed = DirectWorkflow("type \" Second sentence.\"")!
        checkEqual(typed.steps.count, 1)
        checkEqual(typed.steps[0].action.kind, .typeText)
        checkEqual(typed.steps[0].action.text, " Second sentence.")
    }
}
