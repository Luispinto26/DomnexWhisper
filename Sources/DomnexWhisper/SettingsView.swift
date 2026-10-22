import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onPreviewGlow: () -> Void = {}
    @State private var apiKey = ""
    @State private var hasKey = KeychainStore.read(KeychainStore.claudeAccount) != nil

    private let claudeModels = [
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 (mais rápido e barato)"),
    ]

    /// Tabs keep each page shorter than a laptop screen; every page scrolls if it still doesn't fit.
    var body: some View {
        TabView {
            dictationTab
                .tabItem { Label("Ditado", systemImage: "mic") }
            claudeTab
                .tabItem { Label("Claude", systemImage: "sparkles") }
            Form {
                Section("Uso da API do Claude") {
                    UsageSummary(tracker: UsageTracker.shared)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Uso", systemImage: "chart.bar") }
        }
        .padding(.top, 8)
        .frame(width: 500, height: 600)
    }

    private var dictationTab: some View {
        Form {
            Section {
                LaunchAtLoginToggle()
            }
            Section {
                Picker("Tecla para ditar", selection: $settings.hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.label).tag($0) }
                }
                if settings.hotkey == .fn {
                    Text("Em Definições do Sistema › Teclado, muda “Premir a tecla 🌐 para” para “Não fazer nada”, senão abre o painel de emojis.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Idioma", selection: $settings.language) {
                    ForEach(LanguageOption.all) { Text($0.label).tag($0.code) }
                }
                Picker("Modelo de transcrição", selection: $settings.whisperModel) {
                    ForEach(WhisperModelOption.all) { Text($0.label).tag($0.name) }
                }
                Toggle("Brilho à volta do ecrã enquanto gravas", isOn: $settings.edgeGlowEnabled)
                if settings.edgeGlowEnabled, let builtIn = NSScreen.screens.first(where: EdgeGlowView.isBuiltIn) {
                    cornerRadiusControl(automatic: Double(EdgeGlowView.automaticTopCornerRadius(for: builtIn)))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var claudeTab: some View {
        Form {
            Section {
                Toggle("Limpar o texto com o Claude", isOn: $settings.formattingEnabled)
                Picker("Modelo para ditados", selection: $settings.claudeModel) {
                    ForEach(claudeModels, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Modelo para notas de reuniões", selection: $settings.meetingModel) {
                    ForEach(claudeModels, id: \.0) { Text($0.1).tag($0.0) }
                }
                SecureField("Chave da API da Anthropic", text: $apiKey, prompt: Text(hasKey ? "Guardada no Porta-chaves" : "sk-ant-…"))
                HStack {
                    Button("Guardar chave") {
                        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        hasKey = KeychainStore.write(trimmed, account: KeychainStore.claudeAccount)
                        apiKey = ""
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Apagar chave") {
                        KeychainStore.delete(KeychainStore.claudeAccount)
                        hasKey = false
                    }
                    .disabled(!hasKey)
                }
                Text("Só o texto transcrito é enviado à Anthropic. O áudio nunca sai do Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// macOS doesn't expose the display's corner radius, so the user matches it by eye.
    private func cornerRadiusControl(automatic: Double) -> some View {
        let radius = Binding<Double>(
            get: { settings.cornerRadius >= 0 ? settings.cornerRadius : automatic },
            set: { newValue in
                settings.cornerRadius = newValue
                onPreviewGlow()
            }
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Arredondamento dos cantos")
                Spacer()
                Text("\(Int(radius.wrappedValue)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: radius, in: 0...48, step: 1)
            HStack(alignment: .firstTextBaseline) {
                Text("Ajusta até a linha acompanhar a curva dos cantos de cima do ecrã.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Automático") {
                    settings.cornerRadius = -1
                    onPreviewGlow()
                }
                .disabled(settings.cornerRadius < 0)
            }
        }
    }
}

/// Token counts reported by the API, the estimated cost, and an optional remaining-credit estimate.
private struct UsageSummary: View {
    @ObservedObject var tracker: UsageTracker
    @State private var creditText = ""

    var body: some View {
        let month = tracker.state.month
        let total = tracker.state.total
        LabeledContent("Este mês") {
            Text("\(UsageFormat.tokens(month.tokens)) tokens · ≈ \(UsageFormat.dollars(month.costUSD))")
        }
        LabeledContent("Ditados formatados este mês") {
            Text("\(month.requests)")
        }
        LabeledContent("Desde o início") {
            Text("\(UsageFormat.tokens(total.tokens)) tokens · ≈ \(UsageFormat.dollars(total.costUSD))")
        }

        HStack {
            TextField("Créditos carregados (US$)", text: $creditText, prompt: Text("ex.: 5"))
            Button("Guardar") {
                let value = Double(creditText.replacingOccurrences(of: ",", with: "."))
                guard let value, value > 0 else { return }
                tracker.setCredit(value)
                creditText = ""
            }
            .disabled(creditText.isEmpty)
        }
        if let remaining = tracker.estimatedRemainingUSD {
            LabeledContent("Saldo estimado") {
                Text(UsageFormat.dollars(remaining))
                    .foregroundStyle(remaining < 1 ? .orange : .primary)
            }
            Button("Deixar de estimar o saldo") { tracker.setCredit(nil) }
        }

        Text("Contas feitas no Mac com os preços públicos de cada modelo. O saldo real está na consola da Anthropic.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            Link("Abrir faturação na consola", destination: UsageFormat.billingURL)
            Spacer()
            Button("Repor contadores") { tracker.resetCounters() }
        }
    }
}

/// Opens the app at login (System Settings › General › Login Items).
private struct LaunchAtLoginToggle: View {
    @State private var enabled = LaunchAtLogin.isEnabled
    @State private var error: String?

    var body: some View {
        Toggle("Abrir ao iniciar sessão", isOn: Binding(
            get: { enabled },
            set: { newValue in
                do {
                    try LaunchAtLogin.set(newValue)
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
                enabled = LaunchAtLogin.isEnabled
            }
        ))
        if let error {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
    }
}
