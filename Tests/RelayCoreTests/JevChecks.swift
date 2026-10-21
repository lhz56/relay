import Foundation
import RelayCore

@MainActor final class FakeJev: JevTransport {
    var selected = "c0"
    var confidence = 0.99
    var done = 0.99
    var authorized = 0.99
    var commit = 0.0
    var handoff = 0.0
    var states: [[String: Any]] = []
    func evaluate(state: [String: Any], questions: [String: Any]) async throws -> [String: Any] {
        states.append(state)
        var answers: [String: Any] = [:]
        for (name, question) in questions {
            let q = question as! [String: Any]
            if q["type"] as? String == "choice" {
                let criteria = q["criteria"] as! [String: String]
                let choice = name == "action" ? selected : (criteria.keys.first { $0 != "none" } ?? "none")
                answers[name] = ["type": "choice", "choice": choice, "confidence": confidence, "probabilities": criteria.mapValues { _ in 0.0 }.merging([choice: 1.0]) { _, b in b }]
            } else { answers[name] = ["type": "noul", "noul": name == "done" ? done : name == "authorized" ? authorized : name == "commit" ? commit : handoff] }
        }
        return answers
    }
}

@MainActor enum JevChecks {
    static func run() async throws {
        // 1. Bounds and exact extraction, including words from speech.
        let many = (0..<400).map { (index: Int) in ActionCandidate("Button \(index)", Action(kind: .click, target: index)) }
        let obs = Observation(application: "Notes", tree: "Hello", image: Data([99,88]), labels: [1: "Hello"], candidates: many)
        let options = JevPlanner.candidates(task: "Type \"Hello\" then open https://example.com", observation: obs)
        checkTrue(options.count <= 255)
        checkEqual(JevPlanner.textCandidates("type hello then verify"), ["hello"])
        checkTrue(options.values.contains { $0.action.kind == .typeText && $0.action.text == "Hello" })
        // 2. Unknown choices and malformed probabilities cannot reach the executor.
        checkThrows(try JevPlanner.choice(["type": "choice", "choice": "evil", "confidence": 1.0, "probabilities": ["evil": 1.0]], allowed: ["ok"]))
        checkThrows(try JevPlanner.choice(["type": "choice", "choice": "ok", "confidence": 1.0, "probabilities": ["ok": 0.4]], allowed: ["ok"]))
        checkThrows(try JevPlanner.noul(["type": "noul", "noul": 5.0]))
        // 3. Verified finish uses visible evidence; screenshots never enter Jev requests.
        let api = FakeJev()
        let planner = JevPlanner(client: api)
        let complete = try await planner.next(task: "Show Hello", memory: "", history: [], observation: obs)
        checkEqual(complete.action.kind, .finish)
        checkTrue(complete.evidence.contains("Hello"))
        checkTrue(JSONSerialization.isValidJSONObject(api.states[0]))
        let serialized = String(data: try JSONSerialization.data(withJSONObject: api.states[0]), encoding: .utf8)!
        checkFalse(serialized.contains("Y1g="))
        // 4. Incomplete result refuses to claim success.
        api.done = 0.2
        let actual5 = try await awaitDecision(planner, obs: obs)
        checkEqual(actual5, .askUser)
        // 5. Ambiguous choice asks, rather than acting.
        api.selected = "c8"; api.confidence = 0.2
        let actual4 = try await awaitDecision(planner, obs: obs)
        checkEqual(actual4, .askUser)
        // 6. Unauthorized selected action does not execute.
        api.confidence = 0.99; api.authorized = 0.1
        let actual3 = try await awaitDecision(planner, obs: obs)
        checkEqual(actual3, .askUser)
        // 7. Commit classification propagates to approval; handoff propagates to user.
        api.authorized = 0.99; api.commit = 0.9
        let commit = try await planner.next(task: "test", memory: "", history: [], observation: obs)
        checkEqual(commit.risk, "confirm")
        api.handoff = 0.9
        let actual2 = try await awaitDecision(planner, obs: obs)
        checkEqual(actual2, .askUser)
        // 8. Composition never permits the optional writer to operate the computer.
        api.selected = "compose"; api.handoff = 0; api.commit = 0
        let writer = FakePlanner([Decision(summary: "Malicious navigation", action: Action(kind: .openURL, text: "https://example.com"))])
        let restricted = JevPlanner(client: api, writer: writer)
        let actual1 = try await awaitDecision(restricted, obs: obs)
        checkEqual(actual1, .askUser)
    }
    static func awaitDecision(_ planner: Planner, obs: Observation) async throws -> ActionKind {
        try await planner.next(task: "test", memory: "", history: [], observation: obs).action.kind
    }
}
