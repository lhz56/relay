import Foundation
import RelayCore

@MainActor private final class NavigationComputer: Computer {
    var actions: [Action] = []
    var bundleID = "com.apple.finder"
    var address = ""
    func observe() async throws -> Observation {
        Observation(application: "Test app", tree: "PRIVATE_SCREEN", controls: address.isEmpty ? [] : [
            ObservedControl(id: 1, role: "AXTextField", caption: "Address and search bar", value: address, editable: true)
        ], bundleID: bundleID)
    }
    func execute(_ action: Action, observation: Observation) async throws -> String {
        actions.append(action)
        if action.kind == .openApp { bundleID = action.text! }
        if action.kind == .openURL { address = "youtube.com"; bundleID = action.application ?? bundleID }
        return "Executed"
    }
}

@MainActor enum OneCommandChecks {
    static func run() async throws {
        // 1. The original real-world instruction completes via the actual run loop, without a model.
        let api = PrivateTestJev()
        let computer = NavigationComputer()
        let task = "Open Google Chrome, open https://www.youtube.com/, then verify YouTube is open."
        let engine = RunEngine(task: task, planner: RestrictedJevPlanner(client: api), computer: computer)
        engine.start()
        try await RelayCoreTests().waitUntil { engine.record.status == .completed }
        checkEqual(computer.actions.map(\.kind), [.openApp, .openURL])
        checkEqual(computer.actions.last?.application, "com.google.Chrome")
        checkTrue(api.requests.isEmpty)
        // 2. Natural speech and repeated app words keep the ordered intent.
        let spoken = DirectWorkflow("hey open chrome and op open chrome open youtube")!
        checkEqual(spoken.steps.map(\.action.kind), [.openApp, .openURL])
        checkTrue(SpeechIntent.webCandidates("open Google Chrome").isEmpty)
        checkEqual(PrivateTask("open YouTube and open https://www.youtube.com/").urls.count, 1)
        // 3. Unknown extra steps, negations, and misleading verification never disappear.
        for instruction in ["don't open Chrome", "open Chrome then delete a file", "open YouTube play this video",
                            "open YouTube then verify delete everything and YouTube is open", "open YouTube then verify Chrome is open"] {
            checkEqual(DirectWorkflow(instruction)?.steps.count, nil)
        }
        // 4. URL verification requires the right host/path/query, not a substring elsewhere.
        checkTrue(DirectWorkflow.sameURL("youtube.com", "https://www.youtube.com/"))
        for displayed in ["evil.test/?next=https://www.youtube.com/", "youtube.com.evil.test", "youtube.com/watch?v=other", "http://youtube.com/"] {
            checkFalse(DirectWorkflow.sameURL(displayed, "https://www.youtube.com/"))
        }
        checkFalse(DirectWorkflow.sameURL("youtube.com/results?search_query=wrong", "https://www.youtube.com/results?search_query=right"))
        // 5. A failed navigation is observed and bounded, never reported as done or reopened repeatedly.
        let direct = DirectWorkflow("open Chrome then open YouTube")!
        let actions = direct.steps.map(\.action)
        let wrong = Observation(application: "Chrome", tree: "", controls: [
            ObservedControl(id: 1, role: "AXTextField", caption: "Search", value: "https://www.youtube.com/", editable: true)
        ], bundleID: "com.google.Chrome")
        checkEqual(direct.next(after: actions, observation: wrong)?.action.kind, .wait)
        checkEqual(direct.next(after: actions + [Action(kind: .wait), Action(kind: .wait)], observation: wrong)?.action.kind, .askUser)
        // 6. Exact dictated content stays local across open → type → verify.
        let privateAPI = PrivateTestJev()
        let planner = RestrictedJevPlanner(client: privateAPI)
        let dictation = "Open ChatGPT app and write on this thread that hello, um this is my exact wording"
        var obs = Observation(application: "ChatGPT", tree: "", controls: [
            ObservedControl(id: 2, role: "AXTextArea", caption: "Message ChatGPT", focused: true, editable: true)
        ], bundleID: "com.openai.chat")
        let opened = try await planner.next(task: dictation, memory: "", history: [], observation: obs)
        checkEqual(opened.action.kind, .openApp)
        planner.didExecute(opened.action, before: obs)
        let typed = try await planner.next(task: dictation, memory: "", history: [], observation: obs)
        checkEqual(typed.action.text, "hello, um this is my exact wording")
        checkEqual(typed.action.target, 2)
        planner.didExecute(typed.action, before: obs)
        obs.controls[0].value = typed.action.text!
        let verified = try await planner.next(task: dictation, memory: "", history: [], observation: obs)
        checkEqual(verified.action.kind, .finish)
        checkTrue(privateAPI.requests.isEmpty)
    }
}
