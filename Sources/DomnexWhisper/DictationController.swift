import AppKit

/// Hold the hotkey → record → release → transcribe locally → optionally clean up with Claude → paste.
@MainActor
final class DictationController {
    enum ModelState: Equatable {
        case loading
        case downloading(Double)
        case ready
        case failed(String)
    }

    let hotkeys: HotkeyMonitor
    var onChange: (() -> Void)?
    /// Dictation pauses while a meeting is being recorded, since both need the microphone.
    var isPaused: () -> Bool = { false }

    /// The loaded speech model, shared with meeting recordings.
    var readyTranscriber: Transcriber? { modelState == .ready ? transcriber : nil }

    private(set) var modelState: ModelState = .loading {
        didSet { onChange?() }
    }
    private(set) var lastText: String?

    private let settings = AppSettings.shared
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let overlay = OverlayController()
    private var isRecording = false
    private var isProcessing = false
    private var targetApp: NSRunningApplication?

    init() {
        hotkeys = HotkeyMonitor(hotkey: settings.hotkey)
        hotkeys.onPress = { [weak self] in self?.beginRecording() }
        hotkeys.onRelease = { [weak self] in self?.finishRecording() }
        hotkeys.onCancel = { [weak self] in self?.cancelRecording() }
        recorder.onLevel = { [weak self] level in self?.overlay.setLevel(level) }
    }

    func loadModel() {
        let model = settings.whisperModel
        let transcriber = self.transcriber
        modelState = .loading
        Task { [weak self] in
            do {
                try await transcriber.load(model: model) { fraction in
                    Task { @MainActor in
                        self?.modelState = fraction < 1 ? .downloading(fraction) : .loading
                    }
                }
                self?.modelState = .ready
            } catch {
                self?.modelState = .failed(error.localizedDescription)
            }
        }
    }

    func previewEdgeGlow() {
        guard !isRecording, !isProcessing else { return }
        overlay.previewEdgeGlow()
    }

    // MARK: - Hotkey handlers

    private func beginRecording() {
        guard !isRecording, !isProcessing else {
            NSLog("DomnexWhisper: dictation not started (recording=%d, processing=%d)", isRecording, isProcessing)
            if isProcessing { overlay.flash("Ainda a terminar o ditado anterior…") }
            return
        }
        guard !isPaused() else {
            NSLog("DomnexWhisper: dictation not started (meeting in progress)")
            overlay.flash("A gravar uma reunião — o ditado está em pausa")
            return
        }
        guard modelState == .ready else {
            NSLog("DomnexWhisper: dictation not started (model not ready)")
            overlay.flash("O modelo ainda está a carregar…")
            return
        }
        guard Permissions.microphoneStatus == .authorized else {
            NSLog("DomnexWhisper: dictation not started (no microphone permission)")
            overlay.flash("Sem acesso ao microfone")
            Task { _ = await Permissions.requestMicrophone() }
            return
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        do {
            try recorder.start()
        } catch {
            overlay.flash(error.localizedDescription)
            return
        }
        isRecording = true
        overlay.show(.recording)
    }

    /// The hotkey was part of a keyboard shortcut, not a dictation.
    private func cancelRecording() {
        guard isRecording else { return }
        _ = recorder.stop()
        isRecording = false
        overlay.hide()
    }

    private func finishRecording() {
        guard isRecording else { return }
        let samples = recorder.stop()
        isRecording = false

        let duration = Double(samples.count) / AudioRecorder.sampleRate
        // Ignore taps and silence: Whisper tends to invent text for them.
        guard duration >= 0.4, AudioRecorder.rms(samples) > 0.002 else {
            overlay.hide()
            return
        }
        isProcessing = true
        overlay.show(.transcribing)
        Task {
            await process(samples, duration: duration)
            isProcessing = false
        }
    }

    // MARK: - Pipeline

    private func process(_ samples: [Float], duration: Double) async {
        let raw: String
        do {
            raw = try await transcriber.transcribe(samples, language: settings.language)
        } catch {
            overlay.flash("Erro na transcrição")
            NSLog("DomnexWhisper: transcription failed: %@", error.localizedDescription)
            return
        }
        guard !raw.isEmpty else {
            overlay.hide()
            return
        }

        var text = raw
        var formatted = false
        if settings.formattingEnabled, let key = KeychainStore.claudeAPIKey {
            overlay.show(.formatting)
            do {
                text = try await ClaudeFormatter(apiKey: key, model: settings.claudeModel).format(raw)
                formatted = true
            } catch {
                // Never lose a dictation over a network or API problem: paste the raw transcript.
                NSLog("DomnexWhisper: formatting failed, pasting raw transcript: %@", error.localizedDescription)
            }
        }

        HistoryStore.append(.init(
            date: Date(),
            app: targetApp?.bundleIdentifier,
            durationSeconds: duration,
            rawText: raw,
            finalText: text,
            formatted: formatted
        ))
        // Claude returns nothing when the transcript was only noise.
        guard !text.isEmpty else {
            overlay.hide()
            return
        }
        lastText = text
        onChange?()

        if Permissions.accessibilityGranted {
            overlay.hide()
            Paster.paste(text)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            overlay.flash("Copiado — dá acesso de Acessibilidade para colar sozinho", seconds: 4)
        }
    }
}
