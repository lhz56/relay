import Foundation

public enum RelayError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

public enum ActionKind: String, Codable, CaseIterable {
    case observe, openApp, openURL, click, focus, setValue, typeText, copySelection, key, scroll, wait, finish, askUser
}

public struct Action: Codable, Equatable {
    public var kind: ActionKind
    public var target: Int?
    public var text: String?
    public var x: Double?
    public var y: Double?
    public var amount: Int?
    public var application: String?
    public init(kind: ActionKind, target: Int? = nil, text: String? = nil, x: Double? = nil, y: Double? = nil, amount: Int? = nil, application: String? = nil) {
        self.kind = kind; self.target = target; self.text = text; self.x = x; self.y = y; self.amount = amount; self.application = application
    }
    public var fingerprint: String {
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        return String(data: (try? e.encode(self)) ?? Data(), encoding: .utf8) ?? ""
    }
    public func validate() throws {
        switch kind {
        case .openApp, .openURL, .typeText, .key, .askUser:
            guard let text, !text.isEmpty, text.count <= 12000 else { throw RelayError.message("Missing or oversized action text.") }
        case .setValue:
            guard target != nil, text != nil, text!.count <= 12000 else { throw RelayError.message("A field and text are required.") }
        case .focus:
            guard target != nil else { throw RelayError.message("Focus requires an element ID.") }
        case .click:
            guard target != nil || (x != nil && y != nil) else { throw RelayError.message("Click has no target.") }
        case .scroll:
            guard ["up", "down", "left", "right"].contains(text ?? "") else { throw RelayError.message("Invalid scroll direction.") }
        default: break
        }
        if let target, target < 0 { throw RelayError.message("Invalid element ID.") }
        for coordinate in [x, y].compactMap({ $0 }) {
            guard coordinate.isFinite, (0...1).contains(coordinate) else { throw RelayError.message("Coordinates must be normalized between 0 and 1.") }
        }
        if let application {
            guard kind == .openURL, ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"].contains(application) else { throw RelayError.message("Unsupported browser target.") }
        }
        if kind == .openURL {
            guard let url = URL(string: text!), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  url.user == nil, url.password == nil else { throw RelayError.message("Only HTTP(S) web URLs without credentials are allowed.") }
        }
    }
}

public struct Decision: Codable {
    public var summary: String
    public var plan: [String]
    public var completedSteps: Int
    public var memory: String
    public var risk: String
    public var evidence: String
    public var action: Action
    public init(summary: String, plan: [String] = [], completedSteps: Int = 0, memory: String = "", risk: String = "routine", evidence: String = "", action: Action) {
        self.summary = summary; self.plan = plan; self.completedSteps = completedSteps; self.memory = memory
        self.risk = risk; self.evidence = evidence; self.action = action
    }
    public func validate() throws {
        guard ["routine", "confirm", "handoff"].contains(risk), plan.count <= 12, completedSteps >= 0,
              completedSteps <= plan.count, memory.count <= 8000, summary.count <= 2000 else {
            throw RelayError.message("The model returned an invalid decision.")
        }
        try action.validate()
        if action.kind == .finish && evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RelayError.message("The model tried to finish without evidence. Verify the result on screen.")
        }
    }
}

public struct ActionCandidate {
    public var label: String
    public var action: Action
    public var sourceID: Int?
    public init(_ label: String, _ action: Action, sourceID: Int? = nil) { self.label = label; self.action = action; self.sourceID = sourceID }
}
public struct Observation {
    public var application: String
    public var window: String
    public var tree: String
    public var image: Data?
    public var labels: [Int: String]
    public var identity: String
    public var candidates: [ActionCandidate]
    public var controls: [ObservedControl]
    public var bundleID: String
    public var selectionCopied: Bool
    public init(application: String, window: String = "", tree: String, image: Data? = nil, labels: [Int: String] = [:], identity: String = "", candidates: [ActionCandidate] = [], controls: [ObservedControl] = [], bundleID: String = "", selectionCopied: Bool = false) {
        self.application = application; self.window = window; self.tree = tree; self.image = image; self.labels = labels; self.identity = identity
        self.candidates = candidates
        self.controls = controls; self.bundleID = bundleID; self.selectionCopied = selectionCopied
    }
}

/// Values remain local. A planner must explicitly project permitted metadata before networking.
public struct ObservedControl {
    public var id: Int
    public var role: String
    public var caption: String
    public var value: String
    public var focused: Bool
    public var editable: Bool
    public init(id: Int, role: String, caption: String, value: String = "", focused: Bool = false, editable: Bool = false) {
        self.id = id; self.role = role; self.caption = caption; self.value = value; self.focused = focused; self.editable = editable
    }
}

public enum RunStatus: String, Codable {
    case idle, running, paused, approval, waiting, completed, stopped, failed
}
public struct RunEvent: Codable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var title: String
    public var detail: String
    public var executedAction: Action?
    public init(_ title: String, _ detail: String = "", executedAction: Action? = nil) { self.title = title; self.detail = detail; self.executedAction = executedAction }
}
public struct RunRecord: Codable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var task: String
    public var status = RunStatus.idle
    public var plan: [String] = []
    public var completedSteps = 0
    public var memory = ""
    public var events: [RunEvent] = []
    public var decisions = 0
    public init(task: String) { self.task = task }
}
public enum Provider: String, CaseIterable, Codable {
    case jev = "Jev · TypeSafe", gemini = "Gemini", openAI = "OpenAI"
    public var defaultModel: String { switch self { case .jev: return "jev-latest"; case .gemini: return "gemini-3.8-flash"; case .openAI: return "gpt-6-astra" } }
    public var host: String { switch self { case .jev: return "api.typesafe.ai"; case .gemini: return "generativelanguage.googleapis.com"; case .openAI: return "api.openai.com" } }
}

public enum SafetyGate {
    public static func requiresHandoff(_ decision: Decision, observation: Observation) -> Bool {
        guard [.click, .focus, .setValue, .typeText, .key].contains(decision.action.kind) else { return false }
        let control = decision.action.target.flatMap { target in observation.controls.first { $0.id == target } } ?? observation.controls.first { $0.focused }
        let caption = control?.caption ?? decision.action.target.flatMap { observation.labels[$0] } ?? ""
        return caption.range(of: #"\b(password|passcode|verification code|captcha|security settings|grant access|allow access|permission|sign in|log in|accept terms|install)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// These checks are a conservative backstop, not a complete semantic security classifier.
    public static func requiresApproval(_ decision: Decision, observation: Observation) -> Bool {
        if decision.risk != "routine" { return true }
        let action = decision.action
        if [.finish, .observe, .wait, .askUser, .openApp].contains(action.kind) { return false }
        let label = action.target.flatMap { observation.labels[$0] } ?? ""
        let value = [label, decision.summary, action.kind == .key ? action.text ?? "" : ""].joined(separator: " ").lowercased()
        let phrases = ["send", "submit", "publish", "purchase", "buy", "pay", "checkout", "delete", "trash", "remove", "erase", "grant", "allow", "password", "sign in", "log in", "accept", "install", "unsubscribe"]
        if phrases.contains(where: { value.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b", options: .regularExpression) != nil }) { return true }
        // Coordinate clicks lack semantic target information and must be reviewed.
        if action.kind == .click && action.target == nil { return true }
        // A Return key can submit any focused form, including a purchase.
        if action.kind == .key && ["return", "enter"].contains((action.text ?? "").lowercased()) { return true }
        return false
    }
}

public let decisionSchema: [String: Any] = {
    let action: [String: Any] = ["type": "object", "additionalProperties": false,
        "properties": [
            "kind": ["type": "string", "enum": ActionKind.allCases.map(\.rawValue)],
            "target": ["type": ["integer", "null"]], "text": ["type": ["string", "null"]],
            "x": ["type": ["number", "null"]], "y": ["type": ["number", "null"]],
            "amount": ["type": ["integer", "null"]], "application": ["type": ["string", "null"]]
        ], "required": ["kind", "target", "text", "x", "y", "amount", "application"]]
    return ["type": "object", "additionalProperties": false, "properties": [
        "summary": ["type": "string"], "plan": ["type": "array", "items": ["type": "string"]],
        "completedSteps": ["type": "integer"], "memory": ["type": "string"],
        "risk": ["type": "string", "enum": ["routine", "confirm", "handoff"]],
        "evidence": ["type": "string"], "action": action
    ], "required": ["summary", "plan", "completedSteps", "memory", "risk", "evidence", "action"]]
}()
