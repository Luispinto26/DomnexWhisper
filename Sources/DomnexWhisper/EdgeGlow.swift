import AppKit
import CoreImage
import QuartzCore

enum EdgeGlowMode {
    case listening
    case processing
}

/// Animated light around the edges of the screen while dictating. On MacBooks it also wraps
/// around the notch. Everything runs in Core Animation and the masks are rendered once per
/// screen, so the effect costs almost no CPU while it plays.
final class EdgeGlowController {
    private var panel: NSPanel?
    private var glowView: EdgeGlowView?

    func show(_ mode: EdgeGlowMode, on screen: NSScreen) {
        let view = view(for: screen)
        // Same as the pill: a fresh panel for each appearance, so it also shows over full-screen
        // apps. The view and its pre-rendered masks are kept.
        if let old = panel, !old.isVisible {
            old.contentView = nil
            old.close()
            let fresh = Self.makePanel()
            fresh.setFrame(screen.frame, display: false)
            fresh.contentView = view
            panel = fresh
        }
        panel?.orderFrontRegardless()
        view.show(mode)
    }

    func setLevel(_ level: Float) {
        glowView?.setLevel(CGFloat(level))
    }

    func hide() {
        let view = glowView
        view?.fadeOut { [weak self, weak view] in
            // The view may have been replaced (new screen or corner radius) while it faded.
            guard let self, self.glowView === view else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// Renders the masks ahead of time so the first dictation starts instantly.
    func prepare(for screen: NSScreen) {
        _ = view(for: screen)
    }

    private func view(for screen: NSScreen) -> EdgeGlowView {
        let key = EdgeGlowView.key(for: screen)
        if let glowView, let panel, glowView.screenKey == key {
            if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
            return glowView
        }
        let panel = self.panel ?? Self.makePanel()
        panel.setFrame(screen.frame, display: false)
        let view = EdgeGlowView(screen: screen)
        panel.contentView = view
        self.panel = panel
        glowView = view
        return view
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .screenSaver
        // Otherwise the panel hides whenever this app is not the active one.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

final class EdgeGlowView: NSView {
    let screenKey: String

    private let content = CALayer()
    private let hazeLayer = CALayer()
    private let glowLayer = CALayer()
    private let lineLayer = CALayer()
    private let lineMask = CAShapeLayer()
    private var gradients: [CAGradientLayer] = []
    private var mode: EdgeGlowMode?
    private var level: CGFloat = 0
    private var generation = 0
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    private(set) var isShowing = false

    static let palette: [CGColor] = [
        CGColor(srgbRed: 0.24, green: 0.84, blue: 0.95, alpha: 1), // cyan
        CGColor(srgbRed: 0.31, green: 0.48, blue: 1.00, alpha: 1), // blue
        CGColor(srgbRed: 0.61, green: 0.36, blue: 1.00, alpha: 1), // violet
        CGColor(srgbRed: 1.00, green: 0.31, blue: 0.63, alpha: 1), // pink
        CGColor(srgbRed: 1.00, green: 0.62, blue: 0.26, alpha: 1), // orange
        CGColor(srgbRed: 0.24, green: 0.84, blue: 0.95, alpha: 1), // back to cyan, so the loop is seamless
    ]

    static func key(for screen: NSScreen) -> String {
        "\(screen.frame) \(screen.backingScaleFactor) \(String(describing: notchRect(on: screen))) \(topCornerRadius(for: screen))"
    }

    init(screen: NSScreen) {
        screenKey = Self.key(for: screen)
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        super.init(frame: CGRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let notch = Self.notchRect(on: screen)
        let topRadius = Self.topCornerRadius(for: screen)
        let edge = EdgeShape.path(in: bounds, inset: 0, topRadius: topRadius, bottomRadius: 0, notch: notch)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        content.opacity = 0
        layer?.addSublayer(content)

        let haze = CALayer()
        haze.contents = Self.softRing(path: edge, size: size, scale: scale, lineWidth: 40, blur: 42)
        addRing(hazeLayer, mask: haze, opacity: 0.25)

        let glow = CALayer()
        glow.contents = Self.softRing(path: edge, size: size, scale: scale, lineWidth: 22, blur: 18)
        addRing(glowLayer, mask: glow, opacity: 0.55)

        lineMask.path = EdgeShape.path(in: bounds, inset: 1.5, topRadius: topRadius, bottomRadius: 0, notch: notch)
        lineMask.fillColor = nil
        lineMask.strokeColor = NSColor.white.cgColor
        lineMask.lineWidth = 3
        lineMask.lineJoin = .round
        lineMask.contentsScale = scale
        addRing(lineLayer, mask: lineMask, opacity: 1)
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func addRing(_ container: CALayer, mask: CALayer, opacity: Float) {
        container.frame = bounds
        container.opacity = opacity
        let gradient = CAGradientLayer()
        gradient.type = .conic
        gradient.colors = Self.palette
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.frame = bounds
        container.addSublayer(gradient)
        mask.frame = bounds
        container.mask = mask
        content.addSublayer(container)
        gradients.append(gradient)
    }

    // MARK: - States

    func show(_ newMode: EdgeGlowMode) {
        generation += 1
        if !isShowing {
            isShowing = true
            level = 0
            startSpinning()
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.35)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            content.opacity = 1
            CATransaction.commit()
            if !reduceMotion {
                // The line draws itself around the screen as the dictation starts.
                let drawIn = CABasicAnimation(keyPath: "strokeEnd")
                drawIn.fromValue = 0
                drawIn.toValue = 1
                drawIn.duration = 0.7
                drawIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
                lineMask.add(drawIn, forKey: "drawIn")
            }
        }
        guard newMode != mode else { return }
        mode = newMode

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        switch newMode {
        case .listening:
            setSpinSpeed(1)
            glowLayer.removeAnimation(forKey: "pulse")
            glowLayer.opacity = 0.55
            hazeLayer.opacity = 0.25
            lineLayer.opacity = 1
        case .processing:
            setSpinSpeed(3.5)
            hazeLayer.opacity = 0.15
            lineLayer.opacity = 0.8
            if !reduceMotion {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 0.25
                pulse.toValue = 0.75
                pulse.duration = 0.7
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                glowLayer.add(pulse, forKey: "pulse")
            }
        }
        CATransaction.commit()
    }

    /// Microphone RMS level; the glow breathes with the voice while listening.
    func setLevel(_ rms: CGFloat) {
        guard isShowing, mode == .listening else { return }
        let target = min(rms * 12, 1)
        // Rise quickly, fall slowly, so it follows speech without flickering.
        level += (target - level) * (target > level ? 0.5 : 0.15)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        glowLayer.opacity = Float(0.5 + 0.5 * level)
        hazeLayer.opacity = Float(0.2 + 0.45 * level)
        CATransaction.commit()
    }

    func fadeOut(completion: @escaping () -> Void) {
        guard isShowing else { return completion() }
        generation += 1
        let current = generation
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock { [weak self] in
            // A new dictation may have started while this was fading out.
            guard let self, self.generation == current else { return }
            self.isShowing = false
            self.mode = nil
            self.stopSpinning()
            self.glowLayer.removeAnimation(forKey: "pulse")
            completion()
        }
        content.opacity = 0
        CATransaction.commit()
    }

    // MARK: - Rotation

    private func startSpinning() {
        guard !reduceMotion else { return }
        for gradient in gradients where gradient.animation(forKey: "spin") == nil {
            gradient.add(Self.spin(duration: 4.5), forKey: "spin")
        }
    }

    private func stopSpinning() {
        for gradient in gradients {
            gradient.removeAnimation(forKey: "spin")
            gradient.speed = 1
            gradient.timeOffset = 0
            gradient.beginTime = 0
        }
    }

    /// Changes the rotation speed without the colours jumping.
    private func setSpinSpeed(_ speed: Float) {
        guard !reduceMotion else { return }
        let now = CACurrentMediaTime()
        for gradient in gradients {
            gradient.timeOffset = gradient.convertTime(now, from: nil)
            gradient.beginTime = now
            gradient.speed = speed
        }
    }

    /// Rotates a conic gradient by moving its end point around the centre.
    private static func spin(duration: CFTimeInterval) -> CAKeyframeAnimation {
        let steps = 72
        let animation = CAKeyframeAnimation(keyPath: "endPoint")
        animation.values = (0...steps).map { step in
            let angle = Double(step) / Double(steps) * 2 * .pi
            return NSValue(point: NSPoint(x: 0.5 + 0.5 * cos(angle), y: 0.5 + 0.5 * sin(angle)))
        }
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        return animation
    }

    // MARK: - Geometry

    /// The camera notch in view coordinates, or nil on displays without one.
    static func notchRect(on screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let frame = screen.frame
        let height = screen.safeAreaInsets.top
        return CGRect(
            x: left.maxX - frame.minX,
            y: frame.height - height,
            width: right.minX - left.maxX,
            height: height
        )
    }

    /// MacBook built-in displays are rounded at the top; external displays are square.
    /// The user can fine-tune the radius in Settings, since macOS does not expose the real value.
    static func topCornerRadius(for screen: NSScreen) -> CGFloat {
        guard isBuiltIn(screen) else { return 0 }
        let custom = AppSettings.shared.cornerRadius
        return custom >= 0 ? CGFloat(custom) : automaticTopCornerRadius(for: screen)
    }

    /// Set in millimetres and converted to points, so it follows the physical curve whatever
    /// resolution is chosen. 4 mm was matched by eye on a MacBook Neo (Mac17,5).
    static func automaticTopCornerRadius(for screen: NSScreen) -> CGFloat {
        guard let display = displayID(of: screen) else { return 24 }
        let widthInMillimetres = CGDisplayScreenSize(display).width
        guard widthInMillimetres > 0 else { return 24 }
        let pointsPerMillimetre = screen.frame.width / widthInMillimetres
        return (4.0 * pointsPerMillimetre).rounded()
    }

    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let display = displayID(of: screen) else { return false }
        return CGDisplayIsBuiltin(display) != 0
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static let ciContext = CIContext()

    /// A blurred stroke along the edge, used as an alpha mask for the soft glow.
    static func softRing(path: CGPath, size: CGSize, scale: CGFloat, lineWidth: CGFloat, blur: CGFloat) -> CGImage? {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.addPath(path)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineJoin(.round)
        context.strokePath()
        guard let sharp = context.makeImage() else { return nil }

        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        // Clamping makes the light look like it comes from just beyond the edge of the screen.
        let blurred = CIImage(cgImage: sharp)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(blur * scale))
            .cropped(to: extent)
        return ciContext.createCGImage(blurred, from: extent)
    }
}

enum EdgeShape {
    /// Outline of the screen, inset by `inset`, with its own radius for the top and bottom corners,
    /// detouring around the notch if there is one. The radii are reduced by the inset so the
    /// inset outline stays concentric with the screen's corners.
    static func path(in bounds: CGRect, inset: CGFloat, topRadius: CGFloat, bottomRadius: CGFloat, notch: CGRect?) -> CGPath {
        let minX = bounds.minX + inset
        let maxX = bounds.maxX - inset
        let minY = bounds.minY + inset
        let maxY = bounds.maxY - inset
        let top = max(topRadius - inset, 0)
        let bottom = max(bottomRadius - inset, 0)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.midX, y: minY))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: maxY), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY), radius: top)
        if let notch {
            let right = notch.maxX + inset
            let left = notch.minX - inset
            let bottom = notch.minY - inset
            let fillet: CGFloat = 6
            let notchRadius: CGFloat = 8
            path.addLine(to: CGPoint(x: right + fillet, y: maxY))
            path.addQuadCurve(to: CGPoint(x: right, y: maxY - fillet), control: CGPoint(x: right, y: maxY))
            path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: left, y: bottom), radius: notchRadius)
            path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: maxY), radius: notchRadius)
            path.addLine(to: CGPoint(x: left, y: maxY - fillet))
            path.addQuadCurve(to: CGPoint(x: left - fillet, y: maxY), control: CGPoint(x: left, y: maxY))
        }
        path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: minY), radius: top)
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: maxX, y: minY), radius: bottom)
        path.closeSubpath()
        return path
    }
}
