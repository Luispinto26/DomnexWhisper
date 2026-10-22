import AppKit
import SwiftUI

enum OverlayState: Equatable {
    case recording
    case transcribing
    case formatting
    case message(String)

    var label: String {
        switch self {
        case .recording: return "A ouvir…"
        case .transcribing: return "A transcrever…"
        case .formatting: return "A formatar…"
        case let .message(text): return text
        }
    }
}

final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .recording
    @Published var level: Float = 0
}

/// Small floating pill at the bottom of the screen that shows the dictation state.
/// It never takes focus, so the app being dictated into stays active.
final class OverlayController {
    private let model = OverlayModel()
    private let panel: NSPanel
    private let edgeGlow = EdgeGlowController()
    private var hideWork: DispatchWorkItem?
    private var previewWork: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        // NSPanel hides itself whenever this app is not the active one, which is always the case
        // while dictating into another app.
        panel.hidesOnDeactivate = false
        // Above the edge glow, so the pill stays crisp.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard AppSettings.shared.edgeGlowEnabled, let screen = NSScreen.main else { return }
            self?.edgeGlow.prepare(for: screen)
        }
    }

    func show(_ state: OverlayState) {
        hideWork?.cancel()
        model.state = state
        if state != .recording { model.level = 0 }
        let screen = currentScreen()
        position(on: screen)
        panel.orderFrontRegardless()

        guard AppSettings.shared.edgeGlowEnabled, let screen else { return edgeGlow.hide() }
        switch state {
        case .recording: edgeGlow.show(.listening, on: screen)
        case .transcribing, .formatting: edgeGlow.show(.processing, on: screen)
        case .message: edgeGlow.hide()
        }
    }

    /// Shows a short message, then hides itself.
    func flash(_ text: String, seconds: Double = 2.5) {
        show(.message(text))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
        edgeGlow.hide()
    }

    func setLevel(_ level: Float) {
        model.level = level
        edgeGlow.setLevel(level)
    }

    /// Shows the edge glow on the built-in display for a moment, while the corner radius is tuned in Settings.
    func previewEdgeGlow() {
        previewWork?.cancel()
        // Debounced: the masks are re-rendered for every new radius.
        let show = DispatchWorkItem { [weak self] in
            guard let self, let screen = NSScreen.screens.first(where: EdgeGlowView.isBuiltIn) ?? self.currentScreen() else { return }
            self.edgeGlow.show(.listening, on: screen)
            let hide = DispatchWorkItem { [weak self] in self?.edgeGlow.hide() }
            self.previewWork = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: hide)
        }
        previewWork = show
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: show)
    }

    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func position(on screen: NSScreen?) {
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 24))
    }
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            icon
            Text(model.state.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var icon: some View {
        switch model.state {
        case .recording:
            LevelBars(level: model.level)
        case .transcribing, .formatting:
            ProgressView().controlSize(.small).tint(.white)
        case .message:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.white)
        }
    }
}

private struct LevelBars: View {
    let level: Float
    private let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.8, 0.5]

    var body: some View {
        let boosted = min(CGFloat(level) * 12, 1)
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.red)
                    .frame(width: 3, height: 4 + 14 * boosted * weights[index])
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
