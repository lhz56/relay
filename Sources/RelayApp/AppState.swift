import AppKit
import SwiftUI
import ApplicationServices
import RelayCore

@MainActor final class AppState: ObservableObject {
    @Published var tab = "Task"
    @Published var prompt = ""
    @Published var followup = ""
    @Published var screenshots = UserDefaults.standard.object(forKey: "screenshots") as? Bool ?? false
    @Published var setupMessage = ""
    @Published var axGranted = false
    @Published var screenGranted = false
    @Published var testing = false
    @Published var hasKey = false
    @Published var loadingKey = true
    @Published var savingKey = false
    @Published var keyInput = ""
    @Published private var sessionKey: String?
    private var keyRevision = 0
    var hasSessionKey: Bool { sessionKey != nil }
    @Published var run: RunRecord?
    @Published var history: [RunRecord] = []
    @Published var targetPID: Int32 = 0
    @Published var apps: [NSRunningApplication] = []
    @Published var currentApp = ""
    @Published var demo = false
    @Published var spaceHoldReady = false
    @Published var listening = false
    @Published var voiceStarting = false
    @Published var voiceMessage = ""
    @Published var liveTranscript = ""
    @Published var speechPause = UserDefaults.standard.object(forKey: "speechPause") as? Double ?? 0.8
    @Published var queuedVoiceCount = 0
    @Published var lastTiming = ""
    let voice = VoiceInput()
    var voiceGate = LiveVoiceGate()
    var voiceQueue = VoiceWorkQueue()
    var spaceVoiceSession = false
    var dictationMode = false
    var dictationHasText = false
    var voiceRunID: UUID?
    var sessionID = UUID()
    var endpointTask: Task<Void, Never>?
    var rearmTask: Task<Void, Never>?
    var voiceFinishing = false
    var lastVoiceStatus: RunStatus?
    var lastVoiceRun: UUID?
    var reopenWindow: (() -> Void)?
    var refreshShortcuts: (() -> Void)?
    var engine: RunEngine?
    private var applicationObserver: NSObjectProtocol?
    init() {
        // Older consent preferences must never re-enable external AI.
        for key in ["consent", "writerConsent", "writerEnabled", "earlyOpen"] {
            UserDefaults.standard.set(false, forKey: key)
        }
        Task { [weak self] in
            let saved = await KeyStore.shared.read()
            let present = saved != nil ? true : await KeyStore.shared.contains()
            guard let self else { return }
            // A user-entered replacement wins over a delayed startup read.
            if self.keyRevision == 0 { self.sessionKey = saved; self.hasKey = present }
            self.loadingKey = false
        }
        refresh()
        configureVoice()
        applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, !self.isRunning, !self.listening, !self.voiceStarting,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.targetPID = app.processIdentifier
            }
        }
    }
    var isRunning: Bool { run?.status == .running }
    var needsSetup: Bool { !axGranted || (screenshots && !screenGranted) }
    func refresh() {
        axGranted = MacComputer.accessibilityGranted; screenGranted = MacComputer.screenGranted
        refreshShortcuts?()
        apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        if !apps.contains(where: { $0.processIdentifier == targetPID }) { targetPID = NSWorkspace.shared.frontmostApplication.flatMap { front in apps.first { $0.processIdentifier == front.processIdentifier } }?.processIdentifier ?? 0 }
    }
    func settingsChanged() {
        UserDefaults.standard.set(screenshots, forKey: "screenshots")
        UserDefaults.standard.set(speechPause, forKey: "speechPause")
    }
    func useKeyForSession() {
        let value = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        keyRevision += 1; sessionKey = value; keyInput = ""
        setupMessage = "Jev key ready for this session. It will be cleared when Relay quits."
    }
    func saveKey() {
        let value = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !savingKey, !testing else { return }
        keyRevision += 1; sessionKey = value; keyInput = ""; savingKey = true
        setupMessage = "Using your key for this session. Saving to Keychain…"
        Task {
            defer { savingKey = false }
            do { try await KeyStore.shared.save(value); hasKey = true; setupMessage = "Jev key saved in Keychain." }
            catch { setupMessage = "Your key is ready for this session, but macOS did not allow saving it. It will be cleared when Relay quits." }
        }
    }
    func testConnection() {
        guard !testing, !savingKey, !loadingKey else { return }
        let revision = keyRevision
        testing = true; setupMessage = "Checking the saved key and Jev connection…"
        Task {
            defer { testing = false }
            let saved: String?
            if let sessionKey { saved = sessionKey }
            else { saved = await KeyStore.shared.read() }
            guard keyRevision == revision else { return }
            guard let saved else { setupMessage = "The saved key is locked or unavailable. Enter your Jev key above and choose Use for this session. Opening apps, supported sites, copying and literal dictation still work without Jev."; return }
            sessionKey = saved
            do {
                let began = ProcessInfo.processInfo.systemUptime
                let planner = RestrictedJevPlanner(client: RestrictedJevClient(apiKey: saved))
                let decision = try await planner.next(task: "Using the available controls, type \"hello\" then verify it is there.", memory: "", history: [], observation: Observation(application: "Synthetic test", tree: "This raw screen must stay local", controls: [ObservedControl(id: 1, role: "AXTextField", caption: "Message", value: "hello", focused: true, editable: true)]))
                setupMessage = String(format: "Jev connected in %.0f ms. Synthetic privacy test returned %@; no real screen or dictated words were sent.", (ProcessInfo.processInfo.systemUptime - began) * 1000, decision.action.kind.rawValue)
            } catch { setupMessage = error.localizedDescription }
        }
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func requestScreen() { _ = CGRequestScreenCaptureAccess() }
    func show() { reopenWindow?(); NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.identifier?.rawValue == "relay-main" || $0.title == "Relay" })?.makeKeyAndOrderFront(nil) }
    @discardableResult func start(resuming: RunRecord? = nil, initialContext: String? = nil, fromVoice: Bool = false) -> Bool {
        refresh(); settingsChanged()
        guard !isRunning else { return false }
        guard !needsSetup else { tab = "Setup"; setupMessage = "Complete setup before starting a computer task."; return false }
        let task = resuming?.task ?? prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return false }
        let key = sessionKey
        guard DirectWorkflow(task) != nil || key != nil else { tab = "Setup"; setupMessage = "This task needs Jev. Enter your key and choose Use for this session, or test the saved key. Direct commands still work without it."; show(); return false }
        if !fromVoice { voiceQueue.cancel(); queuedVoiceCount = 0 }
        voiceRunID = nil
        if ![.completed, .stopped].contains(engine?.record.status ?? .completed) { engine?.stop() }
        demo = false
        let computer = MacComputer(screenshots: screenshots, initialApp: apps.first { $0.processIdentifier == targetPID }, task: task)
        let next = RunEngine(task: task, planner: RestrictedJevPlanner(client: RestrictedJevClient(apiKey: key ?? "")), computer: computer, record: resuming, initialContext: initialContext)
        voiceRunID = fromVoice ? next.record.id : nil
        attach(next)
        next.onObservation = { [weak self, weak computer] observation in
            self?.currentApp = observation.application
            if let pid = computer?.currentTargetPID { self?.targetPID = pid }
        }
        apps.first { $0.processIdentifier == targetPID }?.activate(options: [])
        NSApp.hide(nil)
        next.start()
        return true
    }
    func attach(_ next: RunEngine) {
        engine = next
        next.onChange = { [weak self] record in
            guard let self else { return }
            self.run = record
            if !self.demo {
                self.history.removeAll { $0.id == record.id }
                self.history.insert(record, at: 0)
                self.history = Array(self.history.prefix(30))
            }
            if [.approval, .waiting, .failed].contains(record.status) { self.show() }
            self.announceStatus(record)
        }
        next.onTiming = { [weak self] observation, planning, action in
            self?.lastTiming = String(format: "Read %.0f ms · Decide %.0f ms · Act %.0f ms", observation * 1000, planning * 1000, action * 1000)
        }
        next.onObservation = { [weak self] observation in self?.currentApp = observation.application }
    }
    func resume() {
        guard let engine else { return }
        NSApp.hide(nil); engine.start()
    }
    func approve() { NSApp.hide(nil); engine?.approve() }
    func sendReply() { let value = followup; followup = ""; NSApp.hide(nil); engine?.reply(value) }
    func pause() { engine?.pause(); show() }
    func stop() { cancelVoice(); voiceQueue.cancel(); queuedVoiceCount = 0; engine?.stop(); show() }
    func runDemo() {
        guard !isRunning else { return }
        engine?.stop(); demo = true; tab = "Task"; currentApp = "Local simulation"
        let next = RunEngine(task: "Practice: create a three-item packing list and verify it.", planner: DemoPlanner(), computer: DemoComputer())
        attach(next); next.start()
    }
}

@MainActor final class DemoComputer: Computer {
    private var stage = 0
    func observe() async throws -> Observation { Observation(application: "Local simulation", tree: "Practice stage \(stage)", identity: "demo-\(stage)") }
    func execute(_ action: Action, observation: Observation) async throws -> String { try await Task.sleep(nanoseconds: 350_000_000); stage += 1; return "Simulated step completed. No real app was changed." }
}
@MainActor final class DemoPlanner: Planner {
    private var index = 0
    func next(task: String, memory: String, history: [RunEvent], observation: Observation) async throws -> Decision {
        try await Task.sleep(nanoseconds: 450_000_000)
        let plan = ["Open a practice note", "Add the packing list", "Verify all three items"]
        let titles = ["Opening a practice note", "Adding passport, charger, and headphones", "Checking the finished list", "Practice complete"]
        let current = min(index, 3); index += 1
        return Decision(summary: titles[current], plan: plan, completedSteps: current, memory: "This is a local simulation.", evidence: current == 3 ? "Simulation passed. No computer control or model API was used." : "", action: Action(kind: current == 3 ? .finish : .observe))
    }
}
