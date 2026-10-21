import Foundation
import RelayCore

@MainActor final class PrivateTestJev: PrivateJevTransport {
    var select = "type_0_1"
    var confidence = 0.99
    var commit = 0.0
    var handoff = 0.0
    var requests: [PrivateJevRequest] = []
    func evaluate(_ request: PrivateJevRequest) async throws -> [String: Any] {
        requests.append(request)
        var answers: [String: Any] = [:]
        for (name, value) in request.questions {
            let question = value as! [String: Any]
            if question["type"] as? String == "choice" {
                let criteria = question["criteria"] as! [String: String]
                let chosen = name == "action" ? select : (criteria.keys.sorted().first(where: { $0 != "none" }) ?? "none")
                answers[name] = ["type": "choice", "choice": chosen, "confidence": confidence, "probabilities": criteria.mapValues { _ in 0.0 }.merging([chosen: 1.0]) { _, b in b }]
            } else { answers[name] = ["type": "noul", "noul": name == "commit" ? commit : name == "handoff" ? handoff : 0.99] }
        }
        return answers
    }
}

private final class RestrictedWire: URLProtocol {
    private static let lock = NSLock()
    private static var seen: [URLRequest] = []
    static var status = 200
    static func reset() { lock.lock(); seen = []; lock.unlock() }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seen.append(request); Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"answers\":{}}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor enum RestrictedChecks {
    static func run() async throws {
        let secret = "Private launch is October 23; email me at person@example.test"
        let hidden = "UNRELATED_EXISTING_CONVERSATION"
        let task = "In the ChatGPT app, write on this thread that \(secret) then verify it is there"
        var screen = Observation(application: "ChatGPT", window: "CONFIDENTIAL_WINDOW", tree: secret + hidden, image: Data("PRIVATE_IMAGE".utf8), labels: [1: secret, 2: hidden], candidates: [ActionCandidate("Focus " + secret, Action(kind: .focus, target: 1)), ActionCandidate("Click " + hidden, Action(kind: .click, target: 2))], controls: [ObservedControl(id: 1, role: "AXTextArea", caption: "Message", value: hidden, focused: true, editable: true), ObservedControl(id: 2, role: "AXButton", caption: hidden)])
        let api = PrivateTestJev()
        let planner = RestrictedJevPlanner(client: api)
        // 1. Original dictated words remain in the local action, never either request.
        let decision = try await planner.next(task: task, memory: hidden, history: [RunEvent("Observed screen", hidden), RunEvent("Initial speech context", hidden)], observation: screen)
        checkEqual(decision.action.text, secret)
        checkEqual(decision.action.target, 1)
        checkEqual(api.requests.count, 2)
        for request in api.requests {
            let json = String(data: try request.data(), encoding: .utf8)!
            for forbidden in [secret, "person@example.test", hidden, "CONFIDENTIAL_WINDOW", "PRIVATE_IMAGE", "action_arguments", "untrusted_screen"] { checkFalse(json.contains(forbidden)) }
            checkTrue(json.contains("local_text_1"))
        }
        // 2. Echoes in a field, control caption, progress and history remain private after execution.
        planner.didExecute(decision.action, before: screen)
        screen.controls[0].value = secret; screen.controls[0].caption = secret
        api.select = "finish"
        let completed = try await planner.next(task: task, memory: secret, history: [RunEvent("Typed", secret)], observation: screen)
        checkEqual(completed.action.kind, .finish)
        let afterTyping = String(data: try api.requests.last!.data(), encoding: .utf8)!
        checkFalse(afterTyping.contains(secret))
        checkTrue(completed.evidence.contains("local_text_1"))
        // 3. Multi-line dictation and multiple follow-ups are masked without losing literal newlines.
        let multiple = PrivateTask("type first private line\nsecond private line then verify it\nUser follow-up: type another private sentence then verify it")
        checkTrue(multiple.dictations.contains("first private line\nsecond private line"))
        for value in ["first private line", "second private line", "another private sentence"] { checkFalse(multiple.instruction.contains(value)) }
        let short = PrivateTask("type text then verify")
        checkTrue(short.instruction.contains("local_text_1"))
        // 4. URLs, search queries and common identifiers stay out of planning text.
        let search = PrivateTask("search YouTube for confidential query then open https://example.test/private?token=secretvalue")
        checkFalse(search.instruction.contains("confidential query"))
        checkFalse(search.instruction.contains("secretvalue"))
        checkTrue(search.urls.contains { $0.action.text?.contains("confidential%20query") == true })
        let pii = PrivateTask("open mail for person@example.test account 123456789")
        checkFalse(pii.instruction.contains("person@example.test")); checkFalse(pii.instruction.contains("123456789"))
        // 5. Private-field contents cannot become control names; only common names and exact local references.
        let vault = PrivateTask("type hello then verify")
        checkEqual(vault.controlName(ObservedControl(id: 1, role: "AXButton", caption: "Send")), "send")
        checkEqual(vault.controlName(ObservedControl(id: 2, role: "AXButton", caption: hidden)), nil)
        checkEqual(vault.controlName(ObservedControl(id: 3, role: "AXTextArea", caption: hidden, value: secret, editable: true)), "editable field")
        // 6. Sensitive access tasks are handed off without any API request.
        let privateAPI = PrivateTestJev()
        let privatePlanner = RestrictedJevPlanner(client: privateAPI)
        let handoff = try await privatePlanner.next(task: "open my banking account", memory: "", history: [], observation: screen)
        checkEqual(handoff.action.kind, .askUser); checkTrue(privateAPI.requests.isEmpty)
        // 7. Unknown actions and low confidence cannot become a computer action.
        api.select = "outside_candidate_set"
        do { _ = try await planner.next(task: task, memory: "", history: [], observation: screen); preconditionFailure("Unknown choice accepted") } catch {}
        api.select = "type_0_1"; api.confidence = 0.3
        let uncertain = try await planner.next(task: task, memory: "", history: [], observation: screen)
        checkEqual(uncertain.action.kind, .askUser)
        // 8. The actual HTTP transport permits only TypeSafe, uses the key header, and refuses redirects.
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RestrictedWire.self]
        RestrictedWire.reset(); RestrictedWire.status = 200
        let transport = RestrictedJevClient(apiKey: "synthetic-key", configuration: config)
        _ = try await transport.evaluate(api.requests[0])
        let request = RestrictedWire.requests()[0]
        checkEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        checkEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        RestrictedWire.status = 302
        do { _ = try await transport.evaluate(api.requests[0]); preconditionFailure("Redirect accepted") } catch {}
        checkEqual(RestrictedWire.requests().count, 2)
        // 9. Commit and credential controls retain independent local safeguards.
        for caption in ["Send", "Delete", "Purchase", "Pay", "Checkout"] {
            let obs = Observation(application: "App", tree: "", labels: [1: caption])
            checkTrue(SafetyGate.requiresApproval(Decision(summary: "Click", action: Action(kind: .click, target: 1)), observation: obs))
        }
        for caption in ["Password", "Grant access", "Security settings", "Verification code"] {
            let obs = Observation(application: "App", tree: "", controls: [ObservedControl(id: 1, role: "AXButton", caption: caption)])
            checkTrue(SafetyGate.requiresHandoff(Decision(summary: "Click", action: Action(kind: .click, target: 1)), observation: obs))
        }
        let sensitiveComputer = FakeComputer(); sensitiveComputer.label = "Grant access"
        let sensitiveEngine = RunEngine(task: "test", planner: FakePlanner([Decision(summary: "Click", action: Action(kind: .click, target: 1))]), computer: sensitiveComputer)
        sensitiveEngine.start()
        try await RelayCoreTests().waitUntil { sensitiveEngine.record.status == .waiting }
        sensitiveEngine.approve()
        checkEqual(sensitiveEngine.record.status, .waiting)
        checkTrue(sensitiveComputer.actions.isEmpty)
        // 10. Navigation uses one request; it cannot include a typed payload or private previous history.
        let nav = PrivateTestJev(); nav.select = "key_tab"
        let moved = try await RestrictedJevPlanner(client: nav).next(task: "focus the next field", memory: secret, history: [RunEvent("Old", hidden)], observation: screen)
        checkEqual(moved.action.text, "tab"); checkEqual(nav.requests.count, 1)
        // 11. Local OCR offers only a permitted control name and keeps coordinates behind approval.
        let ocrAPI = PrivateTestJev(); ocrAPI.select = "click_1001"
        let ocr = Observation(application: "Browser", tree: hidden, labels: [1000: hidden, 1001: "Play (k)"], candidates: [ActionCandidate("Raw OCR: Play (k)", Action(kind: .click, x: 0.4, y: 0.6), sourceID: 1001)], controls: [ObservedControl(id: 1000, role: "OCRText", caption: hidden, value: hidden), ObservedControl(id: 1001, role: "OCRText", caption: "Play (k)", value: "Play (k)")])
        let play = try await RestrictedJevPlanner(client: ocrAPI).next(task: "play this video", memory: "", history: [], observation: ocr)
        checkEqual(play.action.x, 0.4)
        checkTrue(SafetyGate.requiresApproval(play, observation: ocr))
        for request in ocrAPI.requests {
            let body = String(data: try request.data(), encoding: .utf8)!
            checkFalse(body.contains(hidden)); checkFalse(body.contains("Raw OCR")); checkFalse(body.contains("0.4"))
        }
    }
}
