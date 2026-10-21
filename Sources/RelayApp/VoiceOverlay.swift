import AppKit
import Combine
import SwiftUI

/// A silent status capsule that never takes keyboard focus from the target app.
@MainActor final class VoiceOverlay {
    private var panel: NSPanel?
    private var subscription: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var notice = ""
    private var noticeUntil = Date.distantPast
    init(state: AppState) {
        subscription = state.objectWillChange.receive(on: RunLoop.main).sink { [weak self, weak state] in
            guard let self, let state else { return }; self.update(state)
        }
    }
    private func update(_ state: AppState) {
        let active = state.voiceStarting || state.listening || state.isRunning
        let outcome = state.run.map { "\($0.id):\($0.status.rawValue)" } ?? ""
        let message = active ? "" : outcome + ":" + state.voiceMessage
        if !active, message != notice {
            notice = message
            let hasOutcome = [.completed, .failed, .waiting, .approval, .stopped].contains(state.run?.status ?? .idle)
            noticeUntil = hasOutcome || !state.voiceMessage.isEmpty ? Date().addingTimeInterval(state.run?.status == .completed ? 3 : 6) : .distantPast
            hideTask?.cancel()
            hideTask = Task { [weak self, weak state] in
                do { try await Task.sleep(nanoseconds: 6_100_000_000) } catch { return }
                guard let self, let state else { return }; self.update(state)
            }
        }
        guard active || Date() < noticeUntil else { panel?.orderOut(nil); return }
        if panel == nil {
            let next = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 88), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            next.level = .floating; next.isOpaque = false; next.backgroundColor = .clear
            next.hasShadow = true; next.ignoresMouseEvents = true; next.hidesOnDeactivate = false
            next.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            next.contentView = NSHostingView(rootView: CaptureOverlayView(state: state))
            panel = next
        }
        if panel?.isVisible != true, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel?.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 215, y: screen.visibleFrame.maxY - 98))
        }
        panel?.orderFrontRegardless()
    }
}

private struct CaptureOverlayView: View {
    @ObservedObject var state: AppState
    private var busy: Bool { state.voiceStarting || state.listening || state.isRunning }
    private var attention: Bool { [.approval, .waiting, .failed].contains(state.run?.status ?? .idle) }
    private var symbol: String { state.voiceStarting ? "circle.dotted" : state.listening ? "waveform" : state.isRunning ? "sparkle" : attention ? "exclamationmark.circle" : "checkmark.circle" }
    private var title: String {
        state.voiceStarting ? "Getting ready" : state.listening ? (state.isRunning ? "Listening · Working" : "Listening") : state.isRunning ? "Working" : attention ? "Needs your attention" : state.run?.status == .completed ? "Done" : "Microphone off"
    }
    private var detail: String {
        if state.voiceStarting { return "Speak when Listening appears" }
        if state.listening { return state.liveTranscript.isEmpty ? "Keep talking. I’ll take each step in order." : state.liveTranscript }
        if state.isRunning { return state.prompt }
        return state.voiceMessage.isEmpty ? (state.run?.events.last?.detail ?? "Ready when you are") : state.voiceMessage
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: symbol).foregroundStyle(attention ? Color.orange : Color(red: 0.46, green: 0.91, blue: 0.76))
                    .symbolEffect(.pulse, options: .repeating, isActive: busy)
                Text("Relay").font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 4)
                if state.queuedVoiceCount > 0 { Text("+\(state.queuedVoiceCount)").font(.system(size: 11, weight: .medium, design: .monospaced)) }
                if state.listening { Text(state.spaceVoiceSession ? "Release Space" : "⇧⌘V to finish").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)) }
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 18).padding(.vertical, 13).frame(width: 430, height: 88, alignment: .topLeading)
            .foregroundStyle(.white).background(Color(red: 0.045, green: 0.055, blue: 0.065), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12), lineWidth: 1))
            .animation(.easeInOut(duration: 0.18), value: title)
    }
}
