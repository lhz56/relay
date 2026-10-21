import AppKit
import Foundation
import RelayCore

extension AppState {
    func configureVoice() {
        voice.onSpeechActivity = { [weak self] in self?.voiceGate.heardAudio(at: ProcessInfo.processInfo.systemUptime) }
        voice.onText = { [weak self] text in
            guard let self, self.voiceGate.phase != .idle else { return }
            self.voiceGate.update(text, at: ProcessInfo.processInfo.systemUptime)
            self.liveTranscript = self.voiceGate.transcript
        }
        voice.onSegmentEnd = { [weak self] text in
            guard let self, self.voiceGate.phase == .listening else { return }
            self.voiceGate.update(text, at: ProcessInfo.processInfo.systemUptime)
            self.consumeSpeech(final: true)
            if self.voiceGate.phase == .listening { self.voiceGate.nextSegment() }
        }
        voice.onEnd = { [weak self] text, error in self?.finishTranscript(text, error: error) }
    }
    func beginVoiceCommand(held: Bool = false) {
        guard voiceGate.phase == .idle else { return }
        refresh()
        guard !needsSetup else { tab = "Setup"; show(); setupMessage = "Complete setup before starting voice control."; return }
        if !isRunning { captureVoiceTarget() }
        guard voiceGate.arm(pause: speechPause) else { return }
        spaceVoiceSession = held
        voiceStarting = true; liveTranscript = ""; voiceMessage = "Starting microphone…"; tab = "Task"
        let id = sessionID
        rearmTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.voice.start()
                guard self.sessionID == id, self.voiceGate.phase == .preparing, !Task.isCancelled else { return }
                self.voiceGate.captureStarted()
                self.voiceStarting = false; self.listening = true
                self.voiceMessage = held ? "Listening while working. Keep speaking; release Space to stop listening." : "Listening while working. Keep speaking; press ⇧⌘V to stop listening."
                let began = ProcessInfo.processInfo.systemUptime
                self.endpointTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
                        guard let self, self.sessionID == id else { return }
                        self.consumeSpeech()
                        if ProcessInfo.processInfo.systemUptime - began >= 300 {
                            self.finishVoiceCommand(); return
                        }
                    }
                }
            } catch is CancellationError { return }
            catch {
                guard self.sessionID == id else { return }
                self.cancelVoice(); self.voiceMessage = error.localizedDescription; self.show()
            }
        }
    }
    func captureVoiceTarget() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { targetPID = app.processIdentifier }
    }
    func toggleVoice() {
        if voiceStarting { cancelVoice(); return }
        if listening { finishVoiceCommand(); return }
        beginVoiceCommand()
    }
    func releaseSpaceVoice(cancelled: Bool = false) {
        guard spaceVoiceSession else { return }
        if cancelled || voiceStarting { cancelVoice(); return }
        finishVoiceCommand()
    }
    func finishVoiceCommand() {
        guard voiceGate.beginFinishing() else { return }
        listening = false; voiceFinishing = true; voiceMessage = "Microphone off. Finishing your last instruction…"
        endpointTask?.cancel(); endpointTask = nil
        voice.finish() // Audio stops immediately; already accepted work keeps running.
    }
    func consumeSpeech(final: Bool = false) {
        if voiceGate.revisedCommittedSpeech {
            if voiceGate.revisionNeedsPause(at: ProcessInfo.processInfo.systemUptime, final: final) { handleSpeechRevision() }
            return
        }
        while let command = voiceGate.takeReady(at: ProcessInfo.processInfo.systemUptime, final: final) {
            routeSpoken(command)
        }
    }
    func handleSpeechRevision() {
        cancelVoice(); voiceQueue.cancel(); queuedVoiceCount = 0; engine?.pause()
        voiceMessage = "Speech recognition changed an instruction already accepted. Work is paused; say the correction or resume."
        show()
    }
    func finishTranscript(_ text: String, error: String?) {
        guard voiceGate.phase != .idle else { return }
        voiceGate.update(text, at: ProcessInfo.processInfo.systemUptime)
        if voiceGate.revisionNeedsPause(at: ProcessInfo.processInfo.systemUptime, final: true) { handleSpeechRevision(); return }
        if let error {
            cancelVoice(); voiceMessage = error; show(); return
        }
        consumeSpeech(final: true)
        let unfinished = voiceGate.pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelVoice()
        if !unfinished.isEmpty && !["and", "then", "and then"].contains(unfinished.lowercased()) {
            voiceMessage = "Microphone off. The unfinished words were not run: \(unfinished)"
        } else {
            voiceMessage = isRunning || !voiceQueue.commands.isEmpty ? "Microphone off. Finishing your requested steps." : "Microphone off."
        }
        drainVoiceQueue()
    }
    func routeSpoken(_ text: String) {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if ["stop dictation", "stop dictating", "stop transcribing"].contains(lower) {
            dictationMode = false; voiceGate.literal = false; voiceMessage = "Dictation stopped. Listening for instructions."; return
        }
        if !dictationMode, let target = SpeechIntent.dictationTarget(text) {
            dictationMode = true; dictationHasText = false; voiceGate.literal = true
            voiceMessage = "Dictating your words. Say ‘stop dictation’ to return to instructions."
            if target != "current" { voiceQueue.append("open " + target); queuedVoiceCount = voiceQueue.commands.count; drainVoiceQueue() }
            return
        }
        if let control = SpeechIntent.control(text) {
            switch control {
            case .stop, .reject:
                voiceQueue.cancel(); queuedVoiceCount = 0; engine?.stop(); cancelVoice()
            case .pause: engine?.pause()
            case .resume:
                voiceRunID = engine?.record.id
                if [.paused, .failed].contains(run?.status ?? .idle) { resume() }
                else if run?.status == .waiting { followup = "Continue from the current screen."; sendReply() }
                else { drainVoiceQueue() }
            case .approve:
                if run?.status == .approval { voiceRunID = engine?.record.id; approve() }
                else { voiceMessage = "There is no pending action to approve." }
            case .sleep: finishVoiceCommand()
            }
            return
        }
        if dictationMode {
            let literal = (dictationHasText ? " " : "") + text
            dictationHasText = true
            voiceQueue.append("type \"" + literal + "\""); queuedVoiceCount = voiceQueue.commands.count; drainVoiceQueue(); return
        }
        if run?.status == .waiting {
            voiceRunID = engine?.record.id; followup = text; sendReply(); return
        }
        voiceQueue.append(SpeechIntent.normalized(text)); queuedVoiceCount = voiceQueue.commands.count
        drainVoiceQueue()
    }
    func drainVoiceQueue() {
        guard let command = voiceQueue.next(after: run?.status) else { return }
        prompt = command
        if start(fromVoice: true) { voiceQueue.didStart(); queuedVoiceCount = voiceQueue.commands.count }
    }
    /// Cancels capture only. Stop cancels both capture and queued/executing work.
    func cancelVoice() {
        sessionID = UUID(); endpointTask?.cancel(); endpointTask = nil; rearmTask?.cancel(); rearmTask = nil
        voice.cancel(); voiceGate.cancel(); dictationMode = false; dictationHasText = false
        listening = false; voiceStarting = false; voiceFinishing = false; spaceVoiceSession = false
        liveTranscript = ""; voiceMessage = ""
    }
    func announceStatus(_ record: RunRecord) {
        if lastVoiceRun != record.id { lastVoiceRun = record.id; lastVoiceStatus = nil }
        guard lastVoiceStatus != record.status else { return }
        lastVoiceStatus = record.status
        if record.status == .completed && !voiceQueue.commands.isEmpty {
            Task { @MainActor [weak self] in
                guard self?.run?.id == record.id else { return }
                self?.drainVoiceQueue()
            }
            return
        }
        guard voiceRunID == record.id, !demo else { return }
        let message: String
        switch record.status {
        case .completed: message = listening ? "Step done. Still listening." : "Done."
        case .approval: message = "Please review the action in Relay. Later steps are queued."
        case .waiting: message = record.events.last?.detail.isEmpty == false ? record.events.last!.detail : "I need more information."
        case .failed: message = "The task stopped after an error. Later steps are queued."
        default: return
        }
        voiceMessage = message
        // Feedback is visual only, including when the microphone is off.
    }
}
