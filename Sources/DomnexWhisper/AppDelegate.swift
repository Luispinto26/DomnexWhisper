import AppKit
import Combine
import SwiftUI

/// Menu-bar app shell: status item, permission checks, settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    private let controller = DictationController()
    private let meetings = MeetingController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var accessibilityTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.logo ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "DomnexWhisper")
        let menu = NSMenu()
        menu.delegate = self
        // Otherwise AppKit enables every item with a target, ignoring isEnabled.
        menu.autoenablesItems = false
        statusItem.menu = menu

        controller.onChange = { [weak self] in self?.refreshMenu() }
        meetings.onChange = { [weak self] in self?.refreshMenu() }
        controller.isPaused = { [weak self] in self?.meetings.isActive ?? false }
        refreshMenu()

        Task {
            _ = await Permissions.requestMicrophone()
            refreshMenu()
        }
        startHotkeys()
        controller.loadModel()

        settings.$hotkey.dropFirst().sink { [weak self] key in
            self?.controller.hotkeys.hotkey = key
            self?.refreshMenu()
        }.store(in: &subscriptions)
        settings.$whisperModel.dropFirst().removeDuplicates().sink { [weak self] _ in
            // The published value updates after this sink runs; reload on the next turn.
            DispatchQueue.main.async { self?.controller.loadModel() }
        }.store(in: &subscriptions)
    }

    /// The event tap only works once Accessibility is granted, so keep retrying until it is.
    private func startHotkeys() {
        if controller.hotkeys.start() { return }
        Permissions.promptForAccessibility()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                if self.controller.hotkeys.start() {
                    timer.invalidate()
                    self.refreshMenu()
                }
            }
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if !Permissions.accessibilityGranted {
            menu.addItem(item("Dar acesso de Acessibilidade…", #selector(openAccessibility)))
        }
        if Permissions.microphoneStatus == .denied {
            menu.addItem(item("Dar acesso ao microfone…", #selector(openMicrophoneSettings)))
        }
        if settings.formattingEnabled {
            if KeychainStore.claudeAPIKey == nil {
                menu.addItem(item("Adicionar chave da API do Claude…", #selector(showSettings)))
            } else {
                addUsageItems(to: menu)
            }
        }

        menu.addItem(.separator())
        addMeetingItems(to: menu)

        menu.addItem(.separator())
        let copyLast = item("Copiar último ditado", #selector(copyLast))
        copyLast.isEnabled = controller.lastText != nil
        menu.addItem(copyLast)
        menu.addItem(item("Abrir histórico", #selector(openHistory)))
        let login = item("Abrir ao iniciar sessão", #selector(toggleLaunchAtLogin))
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Definições…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Sair do DomnexWhisper", #selector(quit), key: "q"))

        if meetings.isActive {
            // A red record symbol makes it obvious that a meeting is being recorded.
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "DomnexWhisper")
            statusItem.button?.contentTintColor = .systemRed
            statusItem.button?.appearsDisabled = false
        } else {
            statusItem.button?.image = Self.logo ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "DomnexWhisper")
            statusItem.button?.contentTintColor = nil
            statusItem.button?.appearsDisabled = controller.modelState != .ready
        }
    }

    /// The Domnex symbol as a template image, so macOS tints it for light and dark menu bars.
    /// Nil when running outside the app bundle (e.g. `swift run`).
    private static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "Symbol", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "DomnexWhisper"
        let height: CGFloat = 16
        image.size = NSSize(width: height * image.size.width / image.size.height, height: height)
        return image
    }()

    private func addMeetingItems(to menu: NSMenu) {
        if let session = meetings.session, session.isActive {
            let state = session.phase == .recording
                ? "● A gravar reunião · \(Int(session.elapsed / 60)) min"
                : "A preparar as notas da reunião…"
            let line = NSMenuItem(title: state, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
            menu.addItem(item("Mostrar reunião", #selector(showMeeting)))
            if session.phase == .recording {
                menu.addItem(item("Parar e criar notas", #selector(stopMeeting)))
            }
        } else {
            let record = item("Gravar reunião", #selector(startMeeting))
            record.isEnabled = controller.readyTranscriber != nil
            menu.addItem(record)
        }
        menu.addItem(item("Abrir notas de reuniões", #selector(openMeetingNotes)))
    }

    private var statusLine: String {
        switch controller.modelState {
        case .loading:
            return "A preparar o modelo… (a 1.ª vez demora alguns minutos)"
        case let .downloading(fraction):
            return "A descarregar o modelo… \(Int(fraction * 100))%"
        case let .failed(message):
            return "Erro no modelo: \(message)"
        case .ready:
            return controller.hotkeys.isRunning
                ? "Pronto — mantém \(settings.hotkey.label) para ditar"
                : "À espera do acesso de Acessibilidade"
        }
    }

    private func addUsageItems(to menu: NSMenu) {
        let tracker = UsageTracker.shared
        let month = tracker.state.month
        let summary = NSMenuItem(
            title: "Claude este mês: \(UsageFormat.tokens(month.tokens)) tokens · ≈ \(UsageFormat.dollars(month.costUSD))",
            action: nil,
            keyEquivalent: ""
        )
        summary.isEnabled = false
        menu.addItem(summary)
        if let remaining = tracker.estimatedRemainingUSD {
            let balance = NSMenuItem(title: "Saldo estimado: \(UsageFormat.dollars(remaining))", action: nil, keyEquivalent: "")
            balance.isEnabled = false
            menu.addItem(balance)
        }
        menu.addItem(item("Ver saldo na consola da Anthropic…", #selector(openBilling)))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func openAccessibility() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Não foi possível mudar o arranque automático"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
        refreshMenu()
    }

    @objc private func startMeeting() {
        guard let transcriber = controller.readyTranscriber else { return }
        meetings.start(transcriber: transcriber)
    }

    @objc private func stopMeeting() {
        meetings.stop()
    }

    @objc private func showMeeting() {
        meetings.showWindow()
    }

    @objc private func openMeetingNotes() {
        NSWorkspace.shared.open(MeetingNotes.folder)
    }

    @objc private func openBilling() {
        NSWorkspace.shared.open(UsageFormat.billingURL)
    }

    @objc private func copyLast() {
        guard let text = controller.lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openHistory() {
        let url = AppPaths.history
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(AppPaths.support)
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings) { [weak self] in self?.controller.previewEdgeGlow() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Definições do DomnexWhisper"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
