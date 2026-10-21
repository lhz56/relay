import Foundation
import RelayCore

func checkTrue(_ value: @autoclosure () -> Bool, _ message: String = "Expected true", file: StaticString = #filePath, line: UInt = #line) { precondition(value(), "\(file):\(line): \(message)") }
func checkFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { precondition(!value(), "\(file):\(line): Expected false") }
func checkEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { let a = try left(); let b = try right(); precondition(a == b, "\(file):\(line): \(a) != \(b)") } catch { fatalError("\(error)") } }
func checkThrows<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try body() } catch { return }; fatalError("\(file):\(line): Expected an error") }
func checkNoThrow<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try body() } catch { fatalError("\(file):\(line): Unexpected error: \(error)") } }


@MainActor final class FakeComputer: Computer {
    var actions: [Action] = []
    var observations = 0
    var label = "Send"
    var shouldFail = false
    func observe() async throws -> Observation {
        observations += 1
        return Observation(application: "Test", tree: "state \(observations)", labels: [1: label], identity: "test-window")
    }
    func execute(_ action: Action, observation: Observation) async throws -> String {
        if shouldFail { throw RelayError.message("Simulated failure") }
        actions.append(action); return "executed"
    }
}
@MainActor final class FakePlanner: Planner {
    var decisions: [Decision]
    var calls = 0
    var delay: UInt64 = 0
    init(_ decisions: [Decision]) { self.decisions = decisions }
    func next(task: String, memory: String, history: [RunEvent], observation: Observation) async throws -> Decision {
        calls += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return decisions[min(calls - 1, decisions.count - 1)]
    }
}

final class RelayCoreTests {
    func finish() -> Decision { Decision(summary: "Done", evidence: "The new list is visible.", action: Action(kind: .finish)) }
    @MainActor func waitUntil(_ predicate: () -> Bool, seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        checkTrue(predicate(), "Expected state was not reached")
    }
    func testRejectsUnsafeURLSchemesAndInvalidCoordinates() throws {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.com", "https:///", "relay://run"] {
            checkThrows(try Action(kind: .openURL, text: url).validate())
        }
        checkNoThrow(try Action(kind: .openURL, text: "https://example.com").validate())
        checkThrows(try Action(kind: .click, x: 1.1, y: 0.2).validate())
        checkThrows(try Action(kind: .click).validate())
        checkNoThrow(try Action(kind: .setValue, target: 1, text: "").validate())
    }
    func testCompletionRequiresEvidence() {
        checkThrows(try Decision(summary: "Done", action: Action(kind: .finish)).validate())
        checkNoThrow(try finish().validate())
    }
    func testApprovalChecksSemanticLabelsAndCoordinateClicks() {
        let obs = Observation(application: "Mail", tree: "", labels: [1: "Send"])
        checkTrue(SafetyGate.requiresApproval(Decision(summary: "Click", action: Action(kind: .click, target: 1)), observation: obs))
        checkTrue(SafetyGate.requiresApproval(Decision(summary: "Click", action: Action(kind: .click, x: 0.5, y: 0.2)), observation: obs))
        checkTrue(SafetyGate.requiresApproval(Decision(summary: "Continue", action: Action(kind: .key, text: "return")), observation: obs))
        checkFalse(SafetyGate.requiresApproval(Decision(summary: "Focus address", action: Action(kind: .key, text: "cmd+l")), observation: obs))
    }
    @MainActor func testMultiStepLoopObservesBeforeEachDecision() async throws {
        let computer = FakeComputer()
        let planner = FakePlanner([Decision(summary: "Open note", action: Action(kind: .openApp, text: "TextEdit")), Decision(summary: "Write note", action: Action(kind: .typeText, text: "One\nTwo\nThree")), finish()])
        let engine = RunEngine(task: "Write list", planner: planner, computer: computer)
        engine.start()
        try await waitUntil { engine.record.status == .completed }
        checkEqual(computer.actions.count, 2)
        checkEqual(computer.observations, 3)
        checkEqual(engine.record.decisions, 3)
    }
    @MainActor func testStopCancelsInFlightDecisionWithoutAction() async throws {
        let computer = FakeComputer()
        let planner = FakePlanner([Decision(summary: "Write", action: Action(kind: .typeText, text: "Should never be typed"))]); planner.delay = 500_000_000
        let engine = RunEngine(task: "test", planner: planner, computer: computer)
        engine.start()
        try await waitUntil { planner.calls == 1 }
        engine.stop()
        try await Task.sleep(nanoseconds: 600_000_000)
        checkEqual(engine.record.status, .stopped)
        checkTrue(computer.actions.isEmpty)
    }
    @MainActor func testResumeDiscardsStaleModelResponse() async throws {
        let computer = FakeComputer()
        let planner = FakePlanner([Decision(summary: "Old action", action: Action(kind: .typeText, text: "Stale")), finish()]); planner.delay = 400_000_000
        let engine = RunEngine(task: "test", planner: planner, computer: computer)
        engine.start()
        try await waitUntil { planner.calls == 1 }
        engine.pause(); engine.start()
        try await waitUntil { engine.record.status == .completed }
        checkEqual(computer.observations, 2)
        checkTrue(computer.actions.isEmpty)
    }
    @MainActor func testApprovalNeverExecutesUntilApprovedAndReobserved() async throws {
        let computer = FakeComputer()
        let click = Decision(summary: "Send the draft", risk: "confirm", action: Action(kind: .click, target: 1))
        let planner = FakePlanner([click, click, finish()])
        let engine = RunEngine(task: "test", planner: planner, computer: computer)
        engine.start()
        try await waitUntil { engine.record.status == .approval }
        checkTrue(computer.actions.isEmpty)
        engine.approve()
        try await waitUntil { engine.record.status == .completed }
        checkEqual(computer.actions.count, 1)
        checkEqual(computer.observations, 3)
    }
    @MainActor func testChangedTargetInvalidatesApproval() async throws {
        let computer = FakeComputer()
        let click = Decision(summary: "Commit change", risk: "confirm", action: Action(kind: .click, target: 1))
        let engine = RunEngine(task: "test", planner: FakePlanner([click]), computer: computer)
        engine.start()
        try await waitUntil { engine.record.status == .approval }
        computer.label = "Delete account"
        engine.approve()
        try await waitUntil { engine.record.status == .approval }
        checkTrue(computer.actions.isEmpty)
        engine.stop()
    }
    @MainActor func testRepeatedActionStopsInsteadOfLooping() async throws {
        let computer = FakeComputer()
        let engine = RunEngine(task: "test", planner: FakePlanner([Decision(summary: "Wait", action: Action(kind: .observe))]), computer: computer)
        engine.start()
        try await waitUntil { engine.record.status == .waiting }
        checkEqual(computer.actions.count, 2)
        checkTrue(engine.record.events.last!.title.contains("repeating"))
    }
    @MainActor func testStepBudgetStopsRun() async throws {
        let computer = FakeComputer()
        let engine = RunEngine(task: "test", planner: FakePlanner([Decision(summary: "Observe", action: Action(kind: .observe))]), computer: computer, stepLimit: 1)
        engine.start()
        try await waitUntil { engine.record.status == .waiting }
        checkEqual(computer.actions.count, 1)
    }
    @MainActor func testErrorRecoveryHasBound() async throws {
        let computer = FakeComputer(); computer.shouldFail = true
        let engine = RunEngine(task: "test", planner: FakePlanner([
            Decision(summary: "A", action: Action(kind: .typeText, text: "a")),
            Decision(summary: "B", action: Action(kind: .typeText, text: "b")),
            Decision(summary: "C", action: Action(kind: .typeText, text: "c"))]), computer: computer)
        engine.start()
        try await waitUntil { engine.record.status == .failed }
        checkTrue(computer.actions.isEmpty)
    }
    @MainActor func testProviderBodiesAndParsers() throws {
        let decision = String(data: try JSONEncoder().encode(finish()), encoding: .utf8)!
        let openAI: [String: Any] = ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": decision]]]]]
        let gemini: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": decision]]]]
        checkEqual(try ModelClient.parse(provider: .openAI, data: JSONSerialization.data(withJSONObject: openAI)).action.kind, .finish)
        checkEqual(try ModelClient.parse(provider: .gemini, data: JSONSerialization.data(withJSONObject: gemini)).action.kind, .finish)
        checkThrows(try ModelClient.parse(provider: .openAI, data: Data("{\"status\":\"incomplete\"}".utf8)))
        checkThrows(try ModelClient.parse(provider: .gemini, data: Data("{\"choices\":[{\"finish_reason\":\"length\"}]}".utf8)))
        let body = ModelClient.requestBody(provider: .openAI, model: "test-model", prompt: "hello", image: Data([1,2,3]))
        checkEqual(body["store"] as? Bool, false)
        checkTrue(JSONSerialization.isValidJSONObject(body))
        checkTrue(JSONSerialization.isValidJSONObject(ModelClient.requestBody(provider: .gemini, model: "test-model", prompt: "hello", image: nil)))
    }
}

@main struct CheckRunner {
    @MainActor static func main() async throws {
        let tests = RelayCoreTests()
        try tests.testRejectsUnsafeURLSchemesAndInvalidCoordinates()
        tests.testCompletionRequiresEvidence()
        tests.testApprovalChecksSemanticLabelsAndCoordinateClicks()
        try await tests.testMultiStepLoopObservesBeforeEachDecision()
        try await tests.testStopCancelsInFlightDecisionWithoutAction()
        try await tests.testResumeDiscardsStaleModelResponse()
        try await tests.testApprovalNeverExecutesUntilApprovedAndReobserved()
        try await tests.testChangedTargetInvalidatesApproval()
        try await tests.testRepeatedActionStopsInsteadOfLooping()
        try await tests.testStepBudgetStopsRun()
        try await tests.testErrorRecoveryHasBound()
        try tests.testProviderBodiesAndParsers()
        try await JevChecks.run()
        try await VoiceChecks.run()
        SpaceHoldChecks.run()
        try await PrivacyChecks.run()
        try await RestrictedChecks.run()
        try await OneCommandChecks.run()
        try await LiveVoiceChecks.run()
        try await ProductChecks.run()
        ChromeLaunchChecks.run()
        print("PASS: 12 workflow + 8 legacy Jev + 13 voice/navigation + 8 Space-hold + 7 privacy + 11 restricted Jev + 6 direct-workflow + 20 live-voice + 6 product + 5 Chrome launch checks (96 total)")
    }
}
