import AppKit
import AVFoundation
import Speech
import RelayCore

// The audio callback and main-actor recognizer rotation share only this locked sink.
private final class SpeechAudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func replace(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }; request = next
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }; request?.append(buffer)
    }
}

@MainActor final class VoiceInput {
    var onSpeechActivity: (() -> Void)?
    var onText: ((String) -> Void)?
    var onSegmentEnd: ((String) -> Void)?
    var onEnd: ((String, String?) -> Void)?
    private let engine = AVAudioEngine()
    private let sink = SpeechAudioSink()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var segmentID = UUID()
    private var tapping = false
    private var text = ""
    private var finishing = false
    private var rotating = false
    func start() async throws {
        cancel()
        let id = generation
        let auth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == id else { throw CancellationError() }
        guard auth == .authorized else { throw RelayError.message("Enable Speech Recognition for Relay in System Settings, or type your task.") }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == id else { throw CancellationError() }
        guard mic else { throw RelayError.message("Enable Microphone for Relay in System Settings, or type your task.") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw RelayError.message("On-device English speech recognition is unavailable on this Mac. Use text input; no audio was uploaded.")
        }
        self.recognizer = recognizer
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RelayError.message("No microphone input is available.") }
        beginSegment()
        let sink = self.sink
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            sink.append(buffer)
            if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var energy: Float = 0
                for i in 0..<Int(buffer.frameLength) { energy += samples[i] * samples[i] }
                if sqrt(energy / Float(buffer.frameLength)) > 0.006 {
                    Task { @MainActor in guard self?.generation == id else { return }; self?.onSpeechActivity?() }
                }
            }
        }
        tapping = true
        do { engine.prepare(); try engine.start() }
        catch { cancel(); throw error }
    }
    private func beginSegment() {
        guard let recognizer else { return }
        segmentID = UUID(); let segment = segmentID; let session = generation
        text = ""; rotating = false
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true; next.requiresOnDeviceRecognition = true
        next.contextualStrings = AppCatalog.discover().map(\.name)
        request = next; sink.replace(next)
        recognition = recognizer.recognitionTask(with: next) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.generation == session, self.segmentID == segment else { return }
                if let result { self.text = result.bestTranscription.formattedString; self.onText?(self.text) }
                if result?.isFinal == true { self.endSegment() }
                else if let error {
                    // Apple's normal no-speech endpoint can rotate while Space remains held.
                    if self.finishing || self.rotating || (error as NSError).code == 1110 { self.endSegment() }
                    else { self.complete("Speech recognition stopped: \(error.localizedDescription)") }
                }
            }
        }
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 50_000_000_000) } catch { return }
            guard let self, self.segmentID == segment else { return }
            self.rotating = true; self.request?.endAudio(); self.scheduleFinalization()
        }
    }
    private func scheduleFinalization() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            self?.endSegment()
        }
    }
    private func endSegment() {
        if finishing { complete(nil); return }
        let session = generation
        let finalText = text
        segmentID = UUID(); timeout?.cancel(); recognition?.cancel(); recognition = nil
        sink.replace(nil); request = nil
        onSegmentEnd?(finalText)
        // A stop/release from the callback cannot restart recording.
        guard generation == session, !finishing, recognizer != nil else { return }
        beginSegment() // Keep the audio engine running while the recognizer rotates.
    }
    func finish() {
        guard recognizer != nil, !finishing else { return }
        finishing = true
        stopAudio()
        // A spoken "stop listening" can arrive inside the segment-end callback,
        // after the request was cleared but before the next recognizer is created.
        guard request != nil else { complete(nil); return }
        request?.endAudio(); scheduleFinalization()
    }
    private func stopAudio() {
        engine.stop()
        if tapping { engine.inputNode.removeTap(onBus: 0); tapping = false }
    }
    private func complete(_ error: String?) {
        let transcript = text
        cancel()
        onEnd?(transcript, error)
    }
    func cancel() {
        generation = UUID(); segmentID = UUID(); timeout?.cancel(); timeout = nil
        stopAudio(); sink.replace(nil); request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil; recognizer = nil; finishing = false; rotating = false
    }
}
