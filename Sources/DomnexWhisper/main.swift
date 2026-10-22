import AppKit

// Command-line checks that run without the UI or any permissions:
//   DomnexWhisper --test-transcribe <audio file>   downloads/loads the Whisper model and transcribes the file
//   DomnexWhisper --test-format "<text>"           cleans up text with Claude (key from Keychain or ANTHROPIC_API_KEY)
let arguments = CommandLine.arguments

if let index = arguments.firstIndex(of: "--test-transcribe"), index + 1 < arguments.count {
    let path = arguments[index + 1]
    Task {
        let settings = AppSettings.shared
        let transcriber = Transcriber()
        do {
            print("A carregar \(settings.whisperModel)…")
            let start = Date()
            try await transcriber.load(model: settings.whisperModel) { fraction in
                print(String(format: "  download %.0f%%", fraction * 100))
            }
            print(String(format: "Modelo pronto em %.1fs", Date().timeIntervalSince(start)))
            let began = Date()
            let text = try await transcriber.transcribe(fileAt: path, language: settings.language)
            print(String(format: "Transcrição (%.1fs): %@", Date().timeIntervalSince(began), text))
            exit(0)
        } catch {
            print("ERRO: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
}

if let index = arguments.firstIndex(of: "--test-format"), index + 1 < arguments.count {
    let text = arguments[index + 1]
    Task {
        guard let key = KeychainStore.claudeAPIKey else {
            print("ERRO: sem chave da API (Porta-chaves ou ANTHROPIC_API_KEY)")
            exit(1)
        }
        do {
            let began = Date()
            let cleaned = try await ClaudeFormatter(apiKey: key, model: AppSettings.shared.claudeModel).format(text)
            print(String(format: "Formatado (%.1fs): %@", Date().timeIntervalSince(began), cleaned))
            exit(0)
        } catch {
            print("ERRO: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
}

//   DomnexWhisper --demo-glow                      plays the recording animation with a simulated voice, then exits
if arguments.contains("--demo-glow") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let overlay = OverlayController()
        // Give the overlay a moment to pre-render the glow masks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            overlay.show(.recording)
            var elapsed = 0.0
            let voice = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                elapsed += 0.08
                overlay.setLevel(Float(abs(0.07 * sin(elapsed * 5) * sin(elapsed * 1.3))))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                voice.invalidate()
                overlay.show(.transcribing)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { overlay.hide() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.8) { exit(0) }
        }
        app.run()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
