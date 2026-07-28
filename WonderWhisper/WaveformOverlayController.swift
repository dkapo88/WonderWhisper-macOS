import AppKit
import Combine

@MainActor
final class WaveformOverlayController {
    private let window: NSWindow
    private let waveformView = WaveformView()
    private var cancellables: Set<AnyCancellable> = []
    private weak var vm: DictationViewModel?

    private let container = PillContainerView()

    init(viewModel: DictationViewModel) {
        self.vm = viewModel
        // Window is larger than the pill so the soft shadow has room to render.
        let size = NSSize(width: PillMetrics.pillWidth + PillMetrics.shadowPadding * 2,
                          height: PillMetrics.pillHeight + PillMetrics.shadowPadding * 2)
        let rect = NSRect(origin: .zero, size: size)
        let w = NSPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.hasShadow = false
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Enable interaction for cancel/finish buttons
        w.ignoresMouseEvents = false
        w.becomesKeyOnlyIfNeeded = true
        w.isMovableByWindowBackground = false
        container.frame = rect
        container.install(waveformView)
        w.contentView = container
        self.window = w

        // Start hidden and off-screen (not ordered)
        window.alphaValue = 0
        positionAtTopCenter()

        // React to recording state
        viewModel.$isRecording
            .removeDuplicates()
            .sink { [weak self] rec in
                guard let self else { return }
                if rec {
                    self.positionAtTopCenter()
                    self.animateIn()
                    self.waveformView.startAnimating()
                } else {
                    self.waveformView.stopAnimating()
                    self.animateOut()
                }
            }
            .store(in: &cancellables)

        viewModel.$audioLevel
            .sink { [weak self] level in
                self?.waveformView.setLevel(CGFloat(level))
            }
            .store(in: &cancellables)

        // Reposition on screen changes (routed through cancellables to avoid a leaked observer)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.positionAtTopCenter() }
            }
            .store(in: &cancellables)

        // Button actions
        waveformView.onCancel = { [weak self] in self?.vm?.cancel() }
        waveformView.onFinish = { [weak self] in self?.vm?.finish() }
    }

    private func positionAtTopCenter() {
        guard let screen = OverlayScreenResolver.activeScreen() else { return }
        let vf = screen.visibleFrame
        let x = screen.frame.midX - window.frame.width / 2
        // The window is much larger than the pill (transparent shadow padding), so
        // offset by that padding to keep the *pill* just below the menu bar rather
        // than pushing it down by the full window height.
        let y = vf.origin.y + vf.height - window.frame.height + PillMetrics.shadowPadding - 6
        window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    /// Collapsed state: a small dot at the exact centre of the pill.
    ///
    /// AppKit owns the geometry of a layer-backed view's layer and rewrites
    /// `anchorPoint`/`position` on its own schedule, so pinning the anchor is not
    /// reliable — whichever value happened to be live when the animation started
    /// decided the pivot corner, which is why the direction kept changing. Instead
    /// this composes the pivot explicitly (translate to centre, scale, translate
    /// back) from the layer's *current* anchor, so it is correct for any anchor.
    private var collapsedTransform: CATransform3D {
        guard let layer = container.layer else { return CATransform3DIdentity }
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return CATransform3DIdentity }
        let anchor = layer.anchorPoint
        let pivotX = bounds.midX - anchor.x * bounds.width
        let pivotY = bounds.midY - anchor.y * bounds.height
        var transform = CATransform3DMakeTranslation(pivotX, pivotY, 0)
        transform = CATransform3DScale(
            transform,
            PillMetrics.pillHeight / PillMetrics.pillWidth,
            0.34,
            1
        )
        return CATransform3DTranslate(transform, -pivotX, -pivotY, 0)
    }

    private func animateIn() {
        // Force pending layout so the layer's geometry is final before the pivot is
        // computed from it; a mid-animation layout pass is what shifted the pivot.
        container.layoutSubtreeIfNeeded()
        let collapsed = collapsedTransform

        // Seed the collapsed state without animating into it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer?.transform = collapsed
        CATransaction.commit()
        waveformView.setContentVisible(false, animated: false)
        window.alphaValue = 0
        window.orderFrontRegardless()

        // Dot drops from the menu bar and unfurls into the pill.
        let expand = CASpringAnimation(keyPath: "transform")
        expand.fromValue = collapsed
        expand.toValue = CATransform3DIdentity
        expand.damping = 17
        expand.stiffness = 220
        expand.mass = 0.9
        expand.initialVelocity = 3
        expand.duration = expand.settlingDuration
        container.layer?.add(expand, forKey: "present")
        container.layer?.transform = CATransform3DIdentity

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        // Controls and bars fade in once the capsule has most of its width, so they
        // are never seen squashed inside the dot.
        waveformView.setContentVisible(true, animated: true, delay: 0.11)
    }

    private func animateOut() {
        waveformView.setContentVisible(false, animated: true, delay: 0)

        container.layoutSubtreeIfNeeded()
        let collapsed = collapsedTransform
        let collapse = CABasicAnimation(keyPath: "transform")
        collapse.fromValue = container.layer?.presentation()?.transform ?? CATransform3DIdentity
        collapse.toValue = collapsed
        collapse.duration = 0.2
        collapse.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.85, 0.2)
        container.layer?.add(collapse, forKey: "dismiss")
        container.layer?.transform = collapsed

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.7, 0, 1, 0.4)
            ctx.allowsImplicitAnimation = true
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // Order window out after animation to stop blocking mouse events
            self.window.orderOut(nil)
            self.container.layer?.removeAllAnimations()
        })
    }
}

enum PillMetrics {
    static let pillWidth: CGFloat = 128
    static let pillHeight: CGFloat = 28
    /// Must comfortably exceed `shadowRadius + shadowOffset.y`, otherwise the blurred
    /// shadow is clipped by the window edge and the cutoff reads as a grey rectangle.
    static let shadowPadding: CGFloat = 46
    static let buttonSize: CGFloat = 19
    static let shadowRadius: CGFloat = 11
    static let shadowOffsetY: CGFloat = 5
}

/// Hosts the pill and draws its shadow; the pill itself is a masked blur view.
private final class PillContainerView: NSView {
    private var pill: NSView?

    override var isFlipped: Bool { true }

    func install(_ view: NSView) {
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.30
        layer?.shadowOffset = NSSize(width: 0, height: PillMetrics.shadowOffsetY)
        layer?.shadowRadius = PillMetrics.shadowRadius
        addSubview(view)
        pill = view
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = PillMetrics.shadowPadding
        let rect = bounds.insetBy(dx: inset, dy: inset)
        pill?.frame = rect
        layer?.shadowPath = CGPath(
            roundedRect: rect,
            cornerWidth: rect.height / 2,
            cornerHeight: rect.height / 2,
            transform: nil
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        pill?.hitTest(point)
    }
}

enum AudioVisualizerSensitivity {
    static let noiseGate: CGFloat = 0.018
    static let displayZeroThreshold: CGFloat = 0.012
    static let boostExponent: CGFloat = 0.68
    /// Track the meter almost exactly on the way up; the bars should hit peak on the
    /// same frame the syllable does.
    static let inputAttack: CGFloat = 0.95
    /// Fast enough to show gaps between words, slow enough to avoid strobing.
    static let inputRelease: CGFloat = 0.55

    static func gatedLevel(_ value: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, value))
        return clamped < noiseGate ? 0 : clamped
    }

    static func boostedLevel(_ value: CGFloat) -> CGFloat {
        let gated = gatedLevel(value)
        guard gated > 0 else { return 0 }
        return min(1, pow(gated, boostExponent))
    }
}

private final class WaveformView: NSView {
    // Buttons
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    private let cancelButton = CircleButton(kind: .cancel)
    private let finishButton = CircleButton(kind: .finish)
    private let bodyLayer = CAGradientLayer()
    private let tintLayer = CAGradientLayer()
    private let waveLayer = CAShapeLayer()
    private var displayLevel: CGFloat = 0
    private var displayLink: CADisplayLink?
    private let barCount = 15
    /// Per-bar heights, each settling toward the live level at its own rate so the
    /// row breathes as a symmetric equalizer rather than a scrolling history.
    private var barHeights: [CGFloat] = []
    private var phases: [CGFloat] = []
    private var level: CGFloat = 0
    private var contentVisible = true
    private var lastTickTime: CFAbsoluteTime = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 15
        layer?.masksToBounds = true
        isHidden = false
        buildChrome()

        // Hook up buttons
        addSubview(cancelButton)
        addSubview(finishButton)
        cancelButton.onClick = { [weak self] in self?.onCancel?() }
        finishButton.onClick = { [weak self] in self?.onFinish?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        bodyLayer.frame = bounds
        bodyLayer.cornerRadius = bounds.height / 2
        tintLayer.frame = bounds
        waveLayer.frame = bounds

        let btnSize = PillMetrics.buttonSize
        let margin: CGFloat = 5
        cancelButton.frame = NSRect(x: margin, y: (bounds.height - btnSize)/2, width: btnSize, height: btnSize)
        finishButton.frame = NSRect(x: bounds.width - margin - btnSize, y: (bounds.height - btnSize)/2, width: btnSize, height: btnSize)
        cancelButton.layer?.cornerRadius = btnSize / 2
        finishButton.layer?.cornerRadius = btnSize / 2
        redrawWave()
    }

    // Allow clicks only on the buttons so the rest of the pill stays click-through to reduce intrusiveness.
    // `point` arrives in the superview's coordinate space, so convert before testing button frames.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if cancelButton.frame.contains(local) { return cancelButton }
        if finishButton.frame.contains(local) { return finishButton }
        return nil
    }

    func startAnimating() {
        stopAnimating()
        displayLevel = 0
        level = 0
        lastTickTime = 0
        barHeights = Array(repeating: 0, count: barCount)
        // A 30 Hz Timer drifts against the display refresh, so some frames render twice
        // and others are skipped — that beat pattern is the flicker. A display link is
        // delivered in step with the screen instead.
        let link = displayLink(target: self, selector: #selector(handleDisplayLink))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func handleDisplayLink() {
        tick()
    }

    func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
        barHeights = Array(repeating: 0, count: barCount)
        displayLevel = 0
        redrawWave()
    }

    /// Fades the buttons and bars independently of the capsule, so they do not appear
    /// horizontally squashed while the pill is still expanding out of the dot.
    func setContentVisible(_ visible: Bool, animated: Bool, delay: CFTimeInterval = 0) {
        contentVisible = visible
        let targetOpacity: Float = visible ? 1 : 0
        let contentLayers = [tintLayer, cancelButton.layer, finishButton.layer].compactMap { $0 }
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayers.forEach { $0.opacity = targetOpacity }
            CATransaction.commit()
            return
        }
        for contentLayer in contentLayers {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = contentLayer.presentation()?.opacity ?? contentLayer.opacity
            fade.toValue = targetOpacity
            fade.duration = visible ? 0.16 : 0.10
            fade.beginTime = CACurrentMediaTime() + delay
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentLayer.add(fade, forKey: "contentFade")
            contentLayer.opacity = targetOpacity
        }
    }

    private var visualizerRect: NSRect {
        let controls = 5 + PillMetrics.buttonSize + 10
        return NSRect(
            x: controls,
            y: 4,
            width: max(28, bounds.width - controls * 2),
            height: max(8, bounds.height - 8)
        )
    }

    private func buildChrome() {
        guard let root = layer else { return }
        // Drawn capsule rather than NSVisualEffectView: the effect view renders its
        // backdrop as a rectangle whenever its mask is imperfect, which is the faint
        // square that kept showing behind the pill.
        bodyLayer.colors = [
            NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 0.97).cgColor,
            NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.97).cgColor
        ]
        bodyLayer.startPoint = CGPoint(x: 0.5, y: 0)
        bodyLayer.endPoint = CGPoint(x: 0.5, y: 1)
        bodyLayer.cornerCurve = .continuous
        bodyLayer.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        bodyLayer.borderWidth = 0.5
        bodyLayer.zPosition = 0
        root.addSublayer(bodyLayer)

        // Warm signal ramp: amber into a soft coral, which reads as active and
        // premium against the near-black capsule without the alarm of pure red.
        tintLayer.colors = [
            NSColor(srgbRed: 1.00, green: 0.82, blue: 0.35, alpha: 1).cgColor,
            NSColor(srgbRed: 1.00, green: 0.58, blue: 0.31, alpha: 1).cgColor,
            NSColor(srgbRed: 0.99, green: 0.40, blue: 0.42, alpha: 1).cgColor
        ]
        // Diagonal ramp so tall columns pick up more of the hot end of the gradient.
        tintLayer.startPoint = CGPoint(x: 0, y: 1)
        tintLayer.endPoint = CGPoint(x: 1, y: 0)
        tintLayer.zPosition = 2
        waveLayer.fillColor = NSColor.black.cgColor
        tintLayer.mask = waveLayer
        root.addSublayer(tintLayer)
    }

    /// Symmetric equalizer: every bar responds to the current level, weighted so the
    /// centre reaches full height first and the row expands outward as you get louder.
    private func tick() {
        // The display link fires faster than the old 30 Hz timer (and varies with the
        // screen), so the smoothing constants are scaled to elapsed time. Otherwise the
        // same per-frame factors decay far too quickly and the bars stutter.
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = lastTickTime == 0 ? 1.0 / 60.0 : min(0.1, now - lastTickTime)
        lastTickTime = now
        let frames = CGFloat(elapsed * 60)

        // `level` is already the shared MeetingAudioMeter response, matching the
        // meeting bubble. Only a light attack/release smoothing is applied here.
        let perFrame = level > displayLevel
            ? AudioVisualizerSensitivity.inputAttack
            : AudioVisualizerSensitivity.inputRelease
        let alpha = 1 - pow(1 - perFrame, frames)
        displayLevel += (level - displayLevel) * alpha
        if displayLevel < AudioVisualizerSensitivity.displayZeroThreshold { displayLevel = 0 }
        // Decay the held peak so a dropped meter update reads as silence.
        level *= pow(0.72, frames)

        if barHeights.count != barCount { barHeights = Array(repeating: 0, count: barCount) }
        if phases.count != barCount {
            phases = (0..<barCount).map { _ in CGFloat.random(in: 0...(2 * .pi)) }
        }

        let centre = CGFloat(barCount - 1) / 2
        for index in 0..<barCount {
            // Distance from centre: 0 at the middle, 1 at the outer edges.
            let distance = abs(CGFloat(index) - centre) / centre
            // Outer bars need a higher level before they lift, so louder speech
            // visibly pushes the shape outward from the middle.
            let reach = max(0, displayLevel * (1.35 - 0.85 * distance))
            // Small per-bar flutter keeps it alive without inventing fake motion:
            // it scales with the signal, so silence stays perfectly flat.
            let flutter = 1 + 0.16 * sin(now * 9 + Double(phases[index])) * Double(displayLevel)
            let target = min(1, reach * CGFloat(flutter))
            let perFrameRate: CGFloat = target > barHeights[index] ? 0.85 : 0.35
            let rate = 1 - pow(1 - perFrameRate, frames)
            barHeights[index] += (target - barHeights[index]) * rate
        }
        redrawWave()
    }

    private func redrawWave() {
        let rect = visualizerRect
        guard rect.width > 0 else { return }
        let heights = barHeights.isEmpty ? Array(repeating: CGFloat(0), count: barCount) : barHeights
        // Derive pitch from the width so the row always ends inside the pill.
        let pitch = rect.width / CGFloat(barCount)
        let barWidth = max(1, pitch * 0.52)
        let minH = barWidth
        let maxH = rect.height
        let path = CGMutablePath()
        for (index, value) in heights.enumerated() {
            // Bars grow from the vertical centre in both directions.
            let h = minH + (maxH - minH) * min(1, max(0, value))
            let x = rect.minX + pitch * CGFloat(index) + (pitch - barWidth) / 2
            let r = NSRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h)
            path.addRoundedRect(in: r, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        waveLayer.path = path
        CATransaction.commit()
    }

    /// Keep the loudest meter reading between frames; averaging here hid short syllables.
    func setLevel(_ value: CGFloat) {
        level = max(level, max(0, min(1, value)))
    }
}

// MARK: - Circle Buttons

private final class CircleButton: NSView {
    enum Kind { case cancel, finish }
    let kind: Kind
    var onClick: (() -> Void)?
    private var isPressed = false { didSet { updateAppearance() } }
    private var isHovered = false { didSet { updateAppearance() } }
    private var trackingArea: NSTrackingArea?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 11
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowOffset = NSSize(width: 0, height: 1)
        layer?.shadowRadius = 3
        // Accessibility
        setAccessibilityRole(.button)
        setAccessibilityLabel(kind == .cancel ? "Cancel recording" : "Finish recording")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    private func updateAppearance() {
        needsDisplay = true
        // Smooth scale animation on hover/press
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let scale: CGFloat = isPressed ? 0.90 : (isHovered ? 1.06 : 1.0)
            layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.saveGState()

        // Background with hover state
        let bg: NSColor
        switch kind {
        case .cancel:
            let alpha: CGFloat = isPressed ? 0.25 : (isHovered ? 0.19 : 0.12)
            bg = NSColor.white.withAlphaComponent(alpha)
        case .finish:
            let alpha: CGFloat = isPressed ? 0.94 : (isHovered ? 0.88 : 0.78)
            bg = NSColor(srgbRed: 0.42, green: 0.60, blue: 0.98, alpha: alpha)
        }
        bg.setFill()
        let path = NSBezierPath(ovalIn: bounds)
        path.fill()

        // Icon with better contrast
        NSColor.white.setFill()
        NSColor.white.setStroke()
        switch kind {
        case .cancel:
            let inset = max(6, bounds.width * 0.33)
            let lineWidth: CGFloat = 1.7
            let p1 = NSBezierPath()
            p1.move(to: NSPoint(x: inset, y: inset))
            p1.line(to: NSPoint(x: bounds.width - inset, y: bounds.height - inset))
            p1.lineWidth = lineWidth
            p1.lineCapStyle = .round
            p1.stroke()
            let p2 = NSBezierPath()
            p2.move(to: NSPoint(x: bounds.width - inset, y: inset))
            p2.line(to: NSPoint(x: inset, y: bounds.height - inset))
            p2.lineWidth = lineWidth
            p2.lineCapStyle = .round
            p2.stroke()
        case .finish:
            let s = max(6, bounds.width * 0.32)
            let r = NSRect(x: (bounds.width - s)/2, y: (bounds.height - s)/2, width: s, height: s)
            let square = NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5)
            square.fill()
        }
        ctx?.restoreGState()
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside { onClick?() }
    }
}
