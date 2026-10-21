import Foundation

@MainActor public final class RunEngine {
    public private(set) var record: RunRecord
    public private(set) var pending: Decision?
    public var onChange: ((RunRecord) -> Void)?
    public var onTiming: ((Double, Double, Double) -> Void)?
    public var onObservation: ((Observation) -> Void)?
    private let planner: Planner
    private let computer: Computer
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var approved: String?
    private var pendingIdentity = ""
    private var lastFingerprint = ""
    private var repeated = 0
    private var failures = 0
    private let stepLimit: Int
    public init(task: String, planner: Planner, computer: Computer, stepLimit: Int = 60, record: RunRecord? = nil, initialContext: String? = nil) {
        self.record = record ?? RunRecord(task: task)
        if record == nil, let initialContext, !initialContext.isEmpty { self.record.events.append(RunEvent("Initial speech context", initialContext)) }
        self.planner = planner; self.computer = computer; self.stepLimit = stepLimit
    }
    private func notify() { onChange?(record) }
    private func event(_ title: String, _ detail: String = "") { record.events.append(RunEvent(title, detail)); notify() }
    public func start() {
        guard record.status != .running, record.status != .completed else { return }
        generation = UUID()
        let current = generation
        record.status = .running
        pending = nil
        notify()
        worker = Task { await self.loop(current) }
    }
    public func pause() {
        guard record.status == .running else { return }
        generation = UUID(); worker?.cancel(); worker = nil
        record.status = .paused; approved = nil
        event("Paused", "Resume will read fresh screen state before acting.")
    }
    public func stop() {
        generation = UUID(); worker?.cancel(); worker = nil
        pending = nil; approved = nil
        record.status = .stopped
        event("Stopped", "No more actions will be issued.")
    }
    public func approve() {
        guard record.status == .approval, let decision = pending else { return }
        approved = pendingIdentity + "|" + decision.action.fingerprint
        event("User approved one action", decision.summary)
        start()
    }
    public func reply(_ text: String) {
        guard [.waiting, .paused, .failed].contains(record.status), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        record.task += "\nUser follow-up: " + text
        failures = 0; repeated = 0
        event("User follow-up", text)
        start()
    }
    private func active(_ id: UUID) -> Bool { generation == id && record.status == .running && !Task.isCancelled }
    private func loop(_ id: UUID) async {
        while active(id) {
            if record.decisions >= stepLimit {
                record.status = .waiting
                event("Step limit reached", "This run used its \(stepLimit)-decision budget. Start a new task to continue.")
                return
            }
            do {
                let began = Date()
                let observation = try await computer.observe()
                let observed = Date()
                guard active(id) else { return }
                onObservation?(observation)
                event("Observed screen", "\(observation.application) · \(observation.window)\n\(observation.tree.prefix(2500))")
                let decision = try await planner.next(task: record.task, memory: record.memory, history: record.events, observation: observation)
                let planned = Date()
                onTiming?(observed.timeIntervalSince(began), planned.timeIntervalSince(observed), 0)
                guard active(id) else { return }
                record.decisions += 1
                try decision.validate()
                record.plan = decision.plan; record.completedSteps = decision.completedSteps; record.memory = decision.memory
                if decision.action.kind == .finish {
                    record.status = .completed
                    event("Completed", decision.evidence)
                    return
                }
                if decision.action.kind == .askUser || decision.risk == "handoff" {
                    pending = decision; record.status = .waiting
                    event("Your input is needed", decision.action.kind == .askUser ? decision.action.text ?? decision.summary : decision.summary)
                    return
                }
                if SafetyGate.requiresHandoff(decision, observation: observation) {
                    pending = nil; approved = nil; record.status = .waiting
                    event("Your input is needed", "Please handle this credential or security step yourself, then continue.")
                    return
                }
                let identity = observation.identity + "|" + (decision.action.target.flatMap { observation.labels[$0] } ?? "")
                let fingerprint = identity + "|" + decision.action.fingerprint
                if SafetyGate.requiresApproval(decision, observation: observation) && approved != fingerprint {
                    approved = nil; pendingIdentity = identity; pending = decision
                    record.status = .approval
                    event("Review this action", decision.summary)
                    return
                }
                approved = nil
                if fingerprint == lastFingerprint { repeated += 1 } else { repeated = 0; lastFingerprint = fingerprint }
                if repeated >= 2 {
                    record.status = .waiting
                    event("Stopped a repeating action", "The same action was proposed three times. Check the app and give Relay a correction.")
                    return
                }
                event(decision.summary, "Action: \(decision.action.kind.rawValue) · \(observation.application)")
                guard active(id) else { return }
                let result = try await computer.execute(decision.action, observation: observation)
                // Store execution separately from a proposed action; this stays in session memory.
                record.events.append(RunEvent("Executed action", executedAction: decision.action))
                (planner as? ActionObserver)?.didExecute(decision.action, before: observation)
                guard active(id) else { return }
                onTiming?(observed.timeIntervalSince(began), planned.timeIntervalSince(observed), Date().timeIntervalSince(planned))
                event("Action returned", result)
                failures = 0
                try await Task.sleep(nanoseconds: [.openApp, .openURL, .click].contains(decision.action.kind) ? 180_000_000 : 60_000_000)
            } catch is CancellationError { return }
            catch {
                guard active(id) else { return }
                failures += 1
                event("Needs another approach", error.localizedDescription)
                if failures >= 3 {
                    record.status = .failed
                    event("Run paused after errors", "Fix the issue shown above, then add a correction or resume.")
                    return
                }
                do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            }
        }
    }
}
