import AppKit
import Combine

@MainActor
final class WaveformOverlayController {
    private let window: NSWindow
    private let waveformView = WaveformView(style: .pillBars)
    private var cancellables: Set<AnyCancellable> = []
    private weak var vm: DictationViewModel?

    init(viewModel: DictationViewModel) {
        self.vm = viewModel
        let size = NSSize(width: 142, height: 30)
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
        w.contentView = waveformView
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

        // Reposition on screen changes
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.positionAtTopCenter()
            }
        }

        // Button actions
        waveformView.onCancel = { [weak self] in self?.vm?.cancel() }
        waveformView.onFinish = { [weak self] in self?.vm?.finish() }
    }

    private func positionAtTopCenter() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let x = screen.frame.midX - window.frame.width / 2
        // Place just below menu bar area
        let y = vf.origin.y + vf.height - window.frame.height - 8
        window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private func animateIn() {
        window.orderFrontRegardless()
        waveformView.prepareForPresentation()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            ctx.allowsImplicitAnimation = true
            window.animator().alphaValue = 1
            waveformView.layer?.transform = CATransform3DIdentity
        }
    }

    private func animateOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            window.animator().alphaValue = 0
            waveformView.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        }, completionHandler: { [weak self] in
            // Order window out after animation to stop blocking mouse events
            self?.window.orderOut(nil)
        })
    }
}

enum AudioVisualizerSensitivity {
    static let noiseGate: CGFloat = 0.018
    static let displayZeroThreshold: CGFloat = 0.012
    static let boostExponent: CGFloat = 0.68
    static let inputAttack: CGFloat = 0.55
    static let inputRelease: CGFloat = 0.18
    static let levelAttack: CGFloat = 0.56
    static let levelRelease: CGFloat = 0.20
    static let speechFloor: CGFloat = 0.14
    static let wobbleScale: CGFloat = 0.10

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
    enum Style {
        case pillBars      // vertical bars inside a rounded capsule
        case dotTrail      // marching dots that swell with level
        case centerMirror  // mirrored bars from center (oscilloscope vibe)
    }

    private let style: Style
    // Buttons
    var onCancel: (() -> Void)?
    var onFinish: (() -> Void)?
    private let cancelButton = CircleButton(kind: .cancel)
    private let finishButton = CircleButton(kind: .finish)
    private let backgroundLayer = CAGradientLayer()
    private var barLayers: [CALayer] = []
    private var dotLayers: [CALayer] = []
    private var noiseSeeds: [CGFloat] = []
    private var displayLevel: CGFloat = 0
    private var timer: Timer?
    private let barCount = 14
    private var level: CGFloat = 0

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 15
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        layer?.borderWidth = 0.5
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowOffset = NSSize(width: 0, height: 5)
        layer?.shadowRadius = 10
        isHidden = false
        buildChrome()
        switch style {
        case .pillBars, .centerMirror: buildBars()
        case .dotTrail: buildDots()
        }

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
        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: bounds.height / 2,
            cornerHeight: bounds.height / 2,
            transform: nil
        )
        backgroundLayer.frame = bounds
        backgroundLayer.cornerRadius = bounds.height / 2
        layoutBars()

        let btnSize: CGFloat = 22
        let margin: CGFloat = 4
        cancelButton.frame = NSRect(x: margin, y: (bounds.height - btnSize)/2, width: btnSize, height: btnSize)
        finishButton.frame = NSRect(x: bounds.width - margin - btnSize, y: (bounds.height - btnSize)/2, width: btnSize, height: btnSize)
        cancelButton.layer?.cornerRadius = btnSize / 2
        finishButton.layer?.cornerRadius = btnSize / 2
    }

    // Allow clicks only on the buttons so the rest of the pill stays click-through to reduce intrusiveness.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if cancelButton.frame.contains(point) { return cancelButton }
        if finishButton.frame.contains(point) { return finishButton }
        return nil
    }

    func startAnimating() {
        stopAnimating()
        displayLevel = 0
        level = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in barLayers {
            var r = layer.frame
            r.size.height = 3
            r.origin.y = (bounds.height - r.size.height) / 2
            layer.frame = r
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.42).cgColor
        }
        CATransaction.commit()
    }

    func prepareForPresentation() {
        layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
    }

    private var visualizerRect: NSRect {
        let leftControls: CGFloat = 4 + 22 + 12
        let rightControls: CGFloat = 4 + 22 + 10
        return NSRect(
            x: leftControls,
            y: 2,
            width: max(28, bounds.width - leftControls - rightControls),
            height: max(8, bounds.height - 4)
        )
    }

    private func buildChrome() {
        guard let root = layer else { return }
        backgroundLayer.colors = [
            NSColor(calibratedWhite: 0.11, alpha: 0.93).cgColor,
            NSColor(calibratedWhite: 0.045, alpha: 0.95).cgColor
        ]
        backgroundLayer.startPoint = CGPoint(x: 0, y: 0)
        backgroundLayer.endPoint = CGPoint(x: 1, y: 1)
        backgroundLayer.zPosition = 0
        root.addSublayer(backgroundLayer)
    }

    private func buildBars() {
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()
        guard let root = layer else { return }
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.cornerCurve = .continuous
            bar.cornerRadius = 1.5
            bar.zPosition = 2
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.42).cgColor
            bar.shadowColor = NSColor.systemRed.cgColor
            bar.shadowOpacity = 0
            bar.shadowOffset = .zero
            bar.shadowRadius = 2
            root.addSublayer(bar)
            barLayers.append(bar)
        }
        noiseSeeds = (0..<barCount).map { _ in CGFloat.random(in: 0...(2 * .pi)) }
        layoutBars()
    }

    private func layoutBars() {
        guard !barLayers.isEmpty else { return }
        let rect = visualizerRect.insetBy(dx: 1.5, dy: 0.5)
        let availableWidth = rect.width
        let spacing: CGFloat = 2.0
        let barWidth = max(2.0, (availableWidth - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
        var x = rect.minX
        for (i, bar) in barLayers.enumerated() {
            let center = (CGFloat(barCount) - 1) / 2
            let distance = abs(CGFloat(i) - center) / max(1, center)
            let h = 3.0 + 2.2 * (1 - distance)
            bar.frame = NSRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h)
            bar.cornerRadius = barWidth / 2
            x += barWidth + spacing
        }
    }

    private func buildDots() {
        dotLayers.forEach { $0.removeFromSuperlayer() }
        dotLayers.removeAll()
        guard let root = layer else { return }
        let count = 10
        for _ in 0..<count {
            let dot = CALayer()
            dot.cornerCurve = .continuous
            dot.backgroundColor = NSColor.systemRed.cgColor
            root.addSublayer(dot)
            dotLayers.append(dot)
        }
    }

    private func tick() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.09)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        let rect = visualizerRect.insetBy(dx: 1.5, dy: 0.5)
        let minH: CGFloat = 3.0
        let maxH = rect.height
        let now = CFAbsoluteTimeGetCurrent()
        let input = AudioVisualizerSensitivity.boostedLevel(level)
        let attack = AudioVisualizerSensitivity.inputAttack
        let release = AudioVisualizerSensitivity.inputRelease
        if input > displayLevel {
            displayLevel += (input - displayLevel) * attack
        } else {
            displayLevel += (input - displayLevel) * release
        }
        if displayLevel < AudioVisualizerSensitivity.displayZeroThreshold { displayLevel = 0 }

        if !barLayers.isEmpty {
            for (i, bar) in barLayers.enumerated() {
                let center = (CGFloat(barCount) - 1) / 2
                let d = abs(CGFloat(i) - center) / center
                let shape = 0.42 + 0.58 * (1 - d * d)
                let seed = noiseSeeds.indices.contains(i) ? noiseSeeds[i] : 0
                let speed: CGFloat = 0.65 + CGFloat(i % 5) * 0.06
                let wobble = CGFloat(sin(now * Double(7 * speed) + Double(seed)))
                let idleShape: CGFloat = 0.04 + 0.06 * (1 - d)
                let speechFloor = displayLevel > 0 ? AudioVisualizerSensitivity.speechFloor : 0
                let liveShape = (speechFloor + displayLevel * 0.76) * shape
                    + wobble * displayLevel * AudioVisualizerSensitivity.wobbleScale
                var amp = max(idleShape, liveShape)
                if displayLevel == 0 { amp = idleShape }
                amp = max(0, min(1, amp))
                if style == .centerMirror {
                    let falloff = 1 - min(1, abs(CGFloat(i) - center) / center)
                    amp = amp * (0.65 + 0.35 * falloff)
                }
                let h = minH + (maxH - minH) * amp
                var r = bar.frame
                r.size.height = h
                r.origin.y = rect.midY - h / 2
                bar.frame = r
                let alpha = 0.36 + 0.50 * displayLevel
                bar.backgroundColor = NSColor.systemRed.blended(
                    withFraction: 0.55,
                    of: .white
                )?.withAlphaComponent(alpha).cgColor
                bar.shadowOpacity = Float(0.08 + 0.22 * displayLevel)
            }
        } else if !dotLayers.isEmpty {
            let count = dotLayers.count
            let spacing: CGFloat = 6
            let dotSize: CGFloat = 3
            let startX = (bounds.width - (CGFloat(count - 1) * spacing)) / 2
            for (i, dot) in dotLayers.enumerated() {
                let t = CGFloat(i) / CGFloat(max(1, count - 1))
                let delay = Double(t) * 0.25
                // Manual clamp instead of unavailable .clamped
                let sVal = sin((now - delay) * 8)
                let sClamped = max(-1.0, min(1.0, sVal))
                let swell = 0.6 + 0.8 * CGFloat(sClamped)
                let scale = max(0.5, min(1.6, swell * (0.6 + 0.8 * displayLevel)))
                let size = dotSize * scale
                let x = startX + CGFloat(i) * spacing
                dot.frame = NSRect(x: x - size/2, y: (bounds.height - size)/2, width: size, height: size)
                dot.cornerRadius = size/2
            }
        }
        CATransaction.commit()
    }

    func setLevel(_ value: CGFloat) {
        let gated = AudioVisualizerSensitivity.gatedLevel(value)
        let alpha = gated > level
            ? AudioVisualizerSensitivity.levelAttack
            : AudioVisualizerSensitivity.levelRelease
        level = level * (1 - alpha) + gated * alpha
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
            bg = NSColor.systemRed.blended(withFraction: 0.12, of: .white)?.withAlphaComponent(alpha)
                ?? NSColor.systemRed.withAlphaComponent(alpha)
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
            let s = max(7, bounds.width * 0.34)
            let r = NSRect(x: (bounds.width - s)/2, y: (bounds.height - s)/2, width: s, height: s)
            let square = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
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
