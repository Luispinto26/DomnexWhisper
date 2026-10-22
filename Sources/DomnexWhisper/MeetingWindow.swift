import AppKit
import Combine
import SwiftUI

/// Starts and stops meeting recordings and owns the live transcript window.
@MainActor
final class MeetingController {
    var onChange: (() -> Void)?

    private(set) var session: MeetingSession?
    private var window: NSWindow?
    private var subscription: AnyCancellable?

    var isActive: Bool { session?.isActive ?? false }

    func start(transcriber: Transcriber) {
        guard !isActive else { return showWindow() }
        let session = MeetingSession(transcriber: transcriber, language: AppSettings.shared.language)
        do {
            try session.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Não foi possível começar a gravar a reunião"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
            return
        }
        self.session = session
        subscription = session.$phase.sink { [weak self] _ in
            DispatchQueue.main.async { self?.onChange?() }
        }
        window = makeWindow(for: session)
        showWindow()
        onChange?()
    }

    func stop() {
        guard let session, session.phase == .recording else { return }
        Task {
            await session.finish(apiKey: KeychainStore.claudeAPIKey, model: AppSettings.shared.meetingModel)
            if case let .saved(url) = session.phase { NSWorkspace.shared.open(url) }
        }
    }

    func showWindow() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func discard() {
        session?.cancel()
        close()
    }

    private func close() {
        window?.close()
        window = nil
        session = nil
        subscription = nil
        onChange?()
    }

    private func makeWindow(for session: MeetingSession) -> NSWindow {
        let view = MeetingView(
            session: session,
            onStop: { [weak self] in self?.stop() },
            onDiscard: { [weak self] in self?.discard() },
            onClose: { [weak self] in self?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Reunião — DomnexWhisper"
        // Closing the window while recording only hides it; the menu brings it back.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 620))
        window.center()
        return window
    }
}

private struct MeetingView: View {
    @ObservedObject var session: MeetingSession
    let onStop: () -> Void
    let onDiscard: () -> Void
    let onClose: () -> Void
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TextField("Título da reunião", text: $session.title)
                .textFieldStyle(.roundedBorder)
            if session.phase == .recording && !session.heardSystemAudio && session.elapsed > 45 {
                Label(
                    "Ainda não ouvi som do computador. Se a reunião já começou, confirma a permissão em Privacidade e Segurança › Gravação de Ecrã e Áudio do Sistema.",
                    systemImage: "speaker.slash"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            transcript
            footer
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 420)
        .confirmationDialog("Deitar fora esta reunião?", isPresented: $confirmDiscard) {
            Button("Deitar fora", role: .destructive, action: onDiscard)
        } message: {
            Text("A transcrição não é guardada.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            switch session.phase {
            case .recording:
                Circle().fill(Color.red).frame(width: 10, height: 10)
                Text("A gravar")
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("A terminar a transcrição…")
            case .writingNotes:
                ProgressView().controlSize(.small)
                Text("O Claude está a escrever as notas…")
            case .saved:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Notas guardadas")
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(2)
            case .cancelled:
                Text("Cancelada")
            }
            Spacer()
            Text(Self.clock(session.elapsed))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.headline)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.lines.isEmpty {
                        Text("A transcrição aparece aqui de 30 em 30 segundos. Só fica o texto: o áudio é apagado assim que é transcrito.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(session.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(line.speaker.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(line.speaker == .me ? Color.accentColor : Color.purple)
                                Text(Self.clock(line.start))
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Text(line.text).textSelection(.enabled)
                        }
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .onChange(of: session.lines.count) { _, _ in
                if let last = session.lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch session.phase {
            case .recording:
                Button("Deitar fora…", role: .destructive) { confirmDiscard = true }
                Spacer()
                Button("Parar e criar notas", action: onStop)
                    .keyboardShortcut(.defaultAction)
            case .transcribing, .writingNotes:
                Spacer()
                Text("Podes fechar esta janela; a nota abre quando estiver pronta.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .saved(url):
                if let warning = session.notesWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                Spacer()
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Abrir notas") { NSWorkspace.shared.open(url) }
                Button("Fechar", action: onClose).keyboardShortcut(.defaultAction)
            case .failed, .cancelled:
                Spacer()
                Button("Fechar", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
