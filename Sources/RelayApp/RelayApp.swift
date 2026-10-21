import SwiftUI
import AppKit
import RelayCore

@main struct RelayApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("Relay", id: "relay-main") {
            MainView().environmentObject(state)
                .onAppear { delegate.configure(state); state.refresh() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in state.refresh() }
        }
        .defaultSize(width: 1040, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New task") { state.tab = "Task"; state.show() }.keyboardShortcut("n")
                Button("Stop task") { state.stop() }.keyboardShortcut(.escape, modifiers: [.command, .shift])
            }
        }
        MenuBarExtra {
            Text(state.listening ? "Listening while working" : state.isRunning ? "Relay is working in \(state.currentApp)" : "Relay is ready")
            Button("Open Relay  ⇧⌘Space") { state.show() }
            Button(state.listening ? "Stop listening  ⇧⌘V" : "Start listening  ⇧⌘V") { state.toggleVoice() }
            if state.isRunning { Button("Pause") { state.pause() } }
            Button("Stop  ⇧⌘Esc") { state.stop() }.disabled(state.engine == nil && !state.listening)
            Divider()
            Button("Quit Relay") { state.stop(); NSApp.terminate(nil) }
        } label: { Image(systemName: state.listening ? "mic.fill" : state.isRunning ? "arrow.trianglehead.2.clockwise.rotate.90" : "cursorarrow.rays") }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeys: HotKeys?
    private var voiceOverlay: VoiceOverlay?
    func configure(_ state: AppState) {
        guard hotKeys == nil else { return }
        let keys = HotKeys()
        keys.onShow = { [weak state] in state?.captureVoiceTarget(); state?.show() }
        keys.onStop = { [weak state] in state?.stop() }
        keys.onVoice = { [weak state] in state?.toggleVoice() }
        keys.onHandsFree = { [weak state] in state?.toggleVoice() }
        keys.onSpaceStatus = { [weak state] ready in state?.spaceHoldReady = ready }
        keys.onSpaceHold = { [weak state] in
            guard let state, !state.listening, !state.voiceStarting else { return }
            state.beginVoiceCommand(held: true)
        }
        keys.onSpaceRelease = { [weak state] in state?.releaseSpaceVoice() }
        keys.onSpaceCancel = { [weak state] in state?.releaseSpaceVoice(cancelled: true) }
        state.refreshShortcuts = { [weak keys] in keys?.refreshMonitoring() }
        keys.register(); hotKeys = keys
        voiceOverlay = VoiceOverlay(state: state)
    }
    func applicationWillTerminate(_ notification: Notification) { hotKeys?.unregister() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private let ink = Color(red: 0.10, green: 0.17, blue: 0.20)
private let muted = Color(red: 0.43, green: 0.48, blue: 0.47)
private let accent = Color(red: 0.20, green: 0.39, blue: 0.34)
private let canvas = Color(red: 0.97, green: 0.97, blue: 0.94)

struct MainView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        Text(state.tab.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(muted)
                        Spacer()
                        Circle().fill(state.listening ? .red : state.isRunning ? .orange : accent).frame(width: 7, height: 7)
                        Text(state.listening ? "Listening" : state.isRunning ? "Working" : "On demand").font(.system(size: 12)).foregroundStyle(muted)
                    }
                    if state.tab == "Setup" { setupView }
                    else if state.tab == "History" { historyView }
                    else { taskView }
                }.padding(36).frame(maxWidth: 880, alignment: .leading)
            }.background(canvas)
        }.frame(minWidth: 880, minHeight: 640).foregroundStyle(ink).tint(accent).preferredColorScheme(.light)
            .onAppear { state.reopenWindow = { openWindow(id: "relay-main") } }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.rays").font(.system(size: 25, weight: .medium)).foregroundStyle(accent)
                Text("relay").font(.system(size: 28, weight: .semibold, design: .rounded))
            }.padding(.bottom, 15)
            ForEach([("Task", "sparkle"), ("History", "clock"), ("Setup", "slider.horizontal.3")], id: \.0) { item in
                Button { state.tab = item.0 } label: {
                    HStack(spacing: 11) { Image(systemName: item.1).frame(width: 18); Text(item.0); Spacer() }
                        .font(.system(size: 13, weight: .medium)).padding(12)
                        .background(state.tab == item.0 ? accent.opacity(0.09) : .clear).clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 9) {
                Text("ALWAYS WITHIN REACH").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                Text("⇧ ⌘ Space  to open").font(.system(size: 12))
                Text("⇧ ⌘ H  to speak").font(.system(size: 12))
                Text("Hold Space 2.5s  to listen").font(.system(size: 12))
                Text("⇧ ⌘ V  to speak").font(.system(size: 12))
                Text("⇧ ⌘ Esc  to stop").font(.system(size: 12))
            }.foregroundStyle(muted)
            Divider()
            Text("Private dictation\nLimited Jev context.").font(.system(size: 11)).lineSpacing(4).foregroundStyle(muted)
        }.padding(22).frame(width: 192).background(Color.white.opacity(0.72))
    }
    var taskView: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Your computer.\nKeep talking.").font(.system(size: 35, weight: .medium, design: .serif)).lineSpacing(1)
                Text("Hold Space, tell Relay what to do, and keep going while it works.").font(.system(size: 14)).foregroundStyle(muted)
            }
            if state.needsSetup {
                HStack {
                    Image(systemName: "circle.dotted.circle")
                    Text("Enable Mac control to begin. Jev is optional for direct commands.").font(.system(size: 12))
                    Spacer()
                    Button("Set up Relay") { state.tab = "Setup" }.buttonStyle(.borderedProminent)
                }.padding(16).background(accent.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("WHAT WOULD YOU LIKE DONE?").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(muted)
                ZStack(alignment: .topLeading) {
                    if state.prompt.isEmpty { Text("Open Notes, create a new note, type “Hello from Relay”, then verify the text is there.").foregroundStyle(muted.opacity(0.65)).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                    TextEditor(text: $state.prompt).scrollContentBackground(.hidden).font(.system(size: 15)).frame(height: 100).accessibilityLabel("Task instruction")
                }
                Divider()
                HStack {
                    Text(state.queuedVoiceCount > 0 ? "\(state.queuedVoiceCount) more instructions queued" : "Uses the app you’re working in")
                        .font(.system(size: 11)).foregroundStyle(muted)
                    Spacer()
                    Button { state.toggleVoice() } label: { Image(systemName: state.listening ? "stop.circle.fill" : "mic.fill").font(.system(size: 17)) }
                        .accessibilityLabel(state.listening ? "Stop listening" : "Start listening")
                        .help("⇧⌘V to toggle listening")
                    Button { state.start() } label: { Label("Run task", systemImage: "arrow.up.right").padding(.horizontal, 9).padding(.vertical, 4) }
                        .buttonStyle(.borderedProminent).disabled(state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isRunning || state.listening || state.voiceStarting || state.voiceFinishing)
                }
            }.padding(20).background(.white).clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(ink.opacity(0.09)))
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: state.listening ? "waveform.circle.fill" : "waveform.circle").font(.system(size: 25)).foregroundStyle(state.listening ? .red : accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.listening ? "Listening while working" : "Hold. Speak. Keep going.").font(.system(size: 13, weight: .medium))
                        Text(state.listening ? "Keep speaking as Relay works. Release Space to stop listening." : "Hold Space for 2.5 seconds, then keep holding while you speak.").font(.system(size: 11)).foregroundStyle(muted)
                    }
                    Spacer()
                    Button(state.listening ? "Stop listening" : state.voiceStarting ? "Starting…" : "Start listening") { state.toggleVoice() }.buttonStyle(.borderedProminent)
                }
                if !state.liveTranscript.isEmpty { Text(state.liveTranscript).font(.system(size: 14)).textSelection(.enabled) }
            }.padding(16).background(accent.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 12))
            if !state.voiceMessage.isEmpty {
                HStack {
                    Image(systemName: state.listening ? "waveform" : "mic")
                    Text(state.voiceMessage).font(.system(size: 12))
                    Spacer()
                    if state.listening || state.voiceStarting { Button("Cancel") { state.cancelVoice() } }
                }.foregroundStyle(accent)
            }
            if let run = state.run { runView(run) }
            else {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 23)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("See how a workflow feels").font(.system(size: 14, weight: .medium))
                        Text("A local simulation of planning, steps, and verification. No key or permissions needed.").font(.system(size: 12)).foregroundStyle(muted)
                    }
                    Spacer()
                    Button("Try practice run") { state.runDemo() }.buttonStyle(.bordered)
                }.padding(.vertical, 8)
                HStack(spacing: 16) {
                    feature("list.bullet.rectangle", "Plan → act → verify")
                    feature("pause.circle", "Pause & continue")
                    feature("key", "Local dictation")
                }
            }
        }
    }
    func feature(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 11)).foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .leading)
    }
    func runView(_ run: RunRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(state.demo ? "PRACTICE · LOCAL SIMULATION" : "CURRENT RUN").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(muted)
                Spacer()
                Text(run.status.rawValue.capitalized).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 9).padding(.vertical, 5).background(accent.opacity(0.09)).clipShape(Capsule())
            }
            ForEach(Array(run.plan.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 10) {
                    Image(systemName: index < run.completedSteps ? "checkmark.circle.fill" : "circle").foregroundStyle(index < run.completedSteps ? accent : muted.opacity(0.5))
                    Text(step).font(.system(size: 13))
                }
            }
            if !state.lastTiming.isEmpty { Text(state.lastTiming).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted) }
            if let latest = run.events.last {
                VStack(alignment: .leading, spacing: 6) {
                    Text(latest.title).font(.system(size: 14, weight: .medium))
                    if !latest.detail.isEmpty { Text(latest.detail).font(.system(size: 12)).foregroundStyle(muted).textSelection(.enabled) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(ink.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if run.status == .approval, let decision = state.engine?.pending {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Review the next action").font(.system(size: 14, weight: .semibold))
                    Text(decision.summary).font(.system(size: 13))
                    Text(decision.action.fingerprint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    HStack { Button("Approve this action") { state.approve() }.buttonStyle(.borderedProminent); Button("Stop") { state.stop() }.buttonStyle(.bordered) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                if run.status == .running { Button("Pause") { state.pause() }; Button("Stop", role: .destructive) { state.stop() } }
                if [.paused, .failed].contains(run.status) { Button("Resume from current screen") { state.resume() }.buttonStyle(.borderedProminent) }
                Spacer()
                Text("\(run.decisions) / 60 decisions").font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
            }
            if [.waiting, .paused, .failed].contains(run.status) && run.decisions < 60 {
                HStack {
                    TextField("Add a correction or answer…", text: $state.followup).textFieldStyle(.roundedBorder).onSubmit { state.sendReply() }
                    Button("Continue") { state.sendReply() }.disabled(state.followup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            DisclosureGroup("Activity · \(run.events.count) events") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(run.events.suffix(30)) { event in
                        VStack(alignment: .leading, spacing: 3) { Text(event.title).font(.system(size: 12, weight: .medium)); Text(event.detail).font(.system(size: 11)).foregroundStyle(muted) }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.top, 8)
            }.font(.system(size: 12)).foregroundStyle(muted)
        }.padding(20).background(.white).clipShape(RoundedRectangle(cornerRadius: 16))
    }
    var setupView: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("A few things,\nthen you’re ready.").font(.system(size: 34, weight: .medium, design: .serif))
            setupCard("01", "Jev, with limited context") {
                Label("Speech and dictated text stay local", systemImage: "lock.shield").font(.system(size: 13, weight: .medium))
                Text("Jev receives a masked instruction, common control names from the app in your task, and compact progress and verification results. Dictated words, field contents, document text, window titles, screenshots, and past-task history are excluded. Relay does not use Ollama.").font(.system(size: 12)).foregroundStyle(muted)
                HStack {
                    SecureField(state.hasKey ? "Key saved · enter a replacement" : "Jev API key", text: $state.keyInput).textFieldStyle(.roundedBorder).accessibilityLabel("Jev API key")
                    Button(state.savingKey ? "Saving…" : "Save key") { state.saveKey() }.disabled(state.keyInput.isEmpty || state.savingKey || state.testing)
                    Button("Use for this session") { state.useKeyForSession() }.disabled(state.keyInput.isEmpty || state.savingKey || state.testing)
                }
                Text(state.hasSessionKey ? "Jev key ready for this session." : state.loadingKey ? "Checking the saved key…" : state.hasKey ? "A Jev key is saved in Keychain. Test it, or enter the key to use for this session." : "Jev is optional for opening supported apps and sites, copying and literal dictation.").font(.system(size: 11)).foregroundStyle(muted)
                Button(state.testing ? "Checking Jev…" : "Test Jev connection") { state.testConnection() }.disabled(state.testing || state.savingKey || state.loadingKey || (!state.hasKey && !state.hasSessionKey))
                Text("New task history stays in memory until Relay quits. Filtering can miss private details stated outside dictation; avoid putting secrets in commands. Jev's retention terms still apply. If private screen content is needed, Relay asks for your help.").font(.system(size: 11)).foregroundStyle(muted)
            }
            setupCard("02", "Enable Mac control") {
                permissionRow("Accessibility", "Read controls and perform clicks or typing.", state.axGranted, "Enable") { state.requestAccessibility() }
                Divider()
                Toggle("Use local OCR when controls are missing", isOn: $state.screenshots).onChange(of: state.screenshots) { state.settingsChanged() }
                if state.screenshots { permissionRow("Screen Recording", "Read the task window locally; no image or full OCR output is uploaded.", state.screenGranted, "Enable") { state.requestScreen() } }
                Button("Refresh permissions") { state.refresh() }.font(.system(size: 11))
            }
            setupCard("03", "Voice control") {
                Text("Hold Space for 2.5 seconds, then keep holding while you speak. Relay starts complete instructions while you continue talking and carries out each step in order. Release Space to switch the microphone off; accepted steps finish. No wake phrase. ⇧⌘V or ⇧⌘H toggles the same listening mode without a hold. Audio stays on this Mac.").font(.system(size: 12)).foregroundStyle(muted)
                Text(state.spaceHoldReady ? "Space shortcut ready. Short taps type normally; a long hold starts your command without inserting repeated spaces. Modifiers or another physical key end capture. Relay’s own typing does not interrupt listening." : "Accessibility is needed for the global Space shortcut. If keyboard interception is unavailable, use ⇧⌘V; the fallback Space monitor does not suppress repeated spaces.").font(.system(size: 11)).foregroundStyle(muted)
                HStack {
                    Text("Pause between instructions").font(.system(size: 12))
                    Slider(value: $state.speechPause, in: 0.6...2.5, step: 0.1).frame(maxWidth: 180).onChange(of: state.speechPause) { state.settingsChanged() }
                    Text(String(format: "%.1f seconds", state.speechPause)).font(.system(size: 11, design: .monospaced))
                }
                Text("Silent feedback · listening, working, completion, and errors appear near the top of your screen.").font(.system(size: 11)).foregroundStyle(muted)
                Text("Listening continues across completed steps while Space is held. Recognition updates do not repeat accepted commands. Questions and approvals hold later steps in the queue. Relay never speaks back. ⇧⌘Esc cancels listening and all remaining work. Sessions end after five minutes at most.").font(.system(size: 11)).foregroundStyle(muted)
            }
            if !state.setupMessage.isEmpty { Text(state.setupMessage).font(.system(size: 12)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 10)) }
            Button("Back to task") { state.tab = "Task" }.buttonStyle(.borderedProminent)
        }.disabled(state.isRunning || state.listening || state.voiceStarting || state.voiceFinishing)
    }
    func setupCard<Content: View>(_ number: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) { Text(number).font(.system(size: 11, design: .monospaced)).foregroundStyle(accent); Text(title).font(.system(size: 16, weight: .medium)) }
            content()
        }.padding(20).background(.white).clipShape(RoundedRectangle(cornerRadius: 14))
    }
    func permissionRow(_ title: String, _ detail: String, _ enabled: Bool, _ label: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 13, weight: .medium)); Text(detail).font(.system(size: 11)).foregroundStyle(muted) }
            Spacer()
            if enabled { Label("Enabled", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(accent) }
            else { Button(label, action: action) }
        }
    }
    var historyView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("This session’s\nactivity.").font(.system(size: 34, weight: .medium, design: .serif))
            if state.history.isEmpty { Text("Tasks from this app session appear here. New history is not saved to disk.").foregroundStyle(muted) }
            ForEach(state.history) { item in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(item.status.rawValue.capitalized).font(.system(size: 10, weight: .semibold, design: .monospaced)); Spacer(); Text(item.date, style: .date).font(.system(size: 11)).foregroundStyle(muted) }
                    Text(item.task).font(.system(size: 14)).lineLimit(3)
                    Text(item.events.last?.detail ?? "").font(.system(size: 12)).foregroundStyle(muted).lineLimit(3)
                    HStack {
                        Button("Use instruction again") { state.prompt = item.task; state.tab = "Task" }.disabled(state.isRunning)
                        if [.paused, .failed, .stopped, .waiting].contains(item.status) && item.decisions < 60 {
                            Button("Resume workflow") { state.tab = "Task"; state.start(resuming: item) }.disabled(state.isRunning)
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.white).clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}
