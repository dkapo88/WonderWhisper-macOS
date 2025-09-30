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
        let size = NSSize(width: 140, height: 26)  // Slightly wider and taller for better proportions
        let rect = NSRect(origin: .zero, size: size)
        let w = NSPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.hasShadow = true
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Enable interaction for cancel/finish buttons
        w.ignoresMouseEvents = false
        w.becomesKeyOnlyIfNeeded = true
        w.isMovableByWindowBackground = false
        w.contentView = waveformView
        self.window = w

        // Start hidden
        window.alphaValue = 0
        positionAtTopCenter()
        window.orderFrontRegardless()

        // React to recording state
        viewModel.$isRecording
            .removeDuplicates()
            .sink { [weak self] rec in
                guard let self else { return }
                if rec {
                    self.positionAtTopCenter()
                    self.animateIn()
                    self.waveformView.startAnimating()
                    SoundFeedback.playStart()
                } else {
                    self.waveformView.stopAnimating()
                    self.animateOut()
                    SoundFeedback.playStop()
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
        let y = vf.origin.y + vf.height - window.frame.height - 6
        window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    private func animateIn() {
        // Spring animation for more modern feel
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1) // Spring ease
            ctx.allowsImplicitAnimation = true
            window.animator().alphaValue = 1
            // Scale effect via transform
            waveformView.layer?.transform = CATransform3DIdentity
        }
        window.orderFrontRegardless()
    }

    private func animateOut() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ctx.allowsImplicitAnimation = true
            window.animator().alphaValue = 0
            // Subtle scale down
            waveformView.layer?.transform = CATransform3DMakeScale(0.92, 0.92, 1)
        }
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
    private var barLayers: [CALayer] = []
    private var dotLayers: [CALayer] = []
    private var noiseSeeds: [CGFloat] = []
    private var displayLevel: CGFloat = 0
    private var timer: Timer?
    private let barCount = 16
    private var level: CGFloat = 0

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.cornerCurve = .continuous
        // Clean dark background
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        layer?.cornerRadius = 13
        // Subtle border
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        layer?.borderWidth = 0.5
        // Remove shadow to prevent dark halo
        layer?.shadowOpacity = 0
        isHidden = false
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
        layoutBars()

        // Layout buttons - fit to edges with minimal margin
        let btnSize: CGFloat = 20  // Slightly larger for better touch target
        let margin: CGFloat = 3    // Minimal margin to fit to edge
        cancelButton.frame = NSRect(x: margin, y: (bounds.height - btnSize)/2, width: btnSize, height: btnSize)
        finishButton.frame = NSRect(x: bounds.width - margin - btnSize, y: (bounds.height - btnSize)/2, width: btnSize, height: btnSize)
    }

    // Allow clicks only on the buttons so the rest of the pill stays click-through to reduce intrusiveness.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if cancelButton.frame.contains(point) { return cancelButton }
        if finishButton.frame.contains(point) { return finishButton }
        return nil
    }

    func startAnimating() {
        stopAnimating()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
        // Set to a calm state
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in barLayers {
            var r = layer.frame
            r.size.height = bounds.height * 0.28
            r.origin.y = (bounds.height - r.size.height) / 2
            layer.frame = r
            layer.backgroundColor = NSColor.systemRed.cgColor
        }
        CATransaction.commit()
    }

    private func buildBars() {
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()
        guard let root = layer else { return }
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.cornerCurve = .continuous
            bar.cornerRadius = 1.8
            bar.backgroundColor = NSColor.systemRed.cgColor
            // Very subtle glow - reduced to prevent visual clutter
            bar.shadowColor = NSColor.systemRed.cgColor
            bar.shadowOpacity = 0.25
            bar.shadowOffset = .zero
            bar.shadowRadius = 1.5
            root.addSublayer(bar)
            barLayers.append(bar)
        }
        noiseSeeds = (0..<barCount).map { _ in CGFloat.random(in: 0...(2 * .pi)) }
        layoutBars()
    }

    private func layoutBars() {
        guard !barLayers.isEmpty else { return }
        // Reserve space for left/right buttons - buttons now fit to edge
        let btnSize: CGFloat = 20
        let sideInset: CGFloat = 3 + btnSize + 4  // Minimal spacing
        let insetX: CGFloat = sideInset
        let insetY: CGFloat = 4  // Reduced for more vertical space
        let availableWidth = bounds.width - insetX * 2
        let availableHeight = bounds.height - insetY * 2
        let spacing: CGFloat = 1.5
        let barWidth = max(1.2, (availableWidth - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
        var x = insetX
        for (i, bar) in barLayers.enumerated() {
            let base: CGFloat
            if style == .centerMirror {
                // subtle center emphasis
                let t = abs(CGFloat(i) - CGFloat(barCount - 1)/2) / (CGFloat(barCount)/2)
                base = (0.30 + 0.20 * (1 - t))  // Increased base heights
            } else {
                base = 0.35  // Increased from 0.28 for more visible bars
            }
            let h = max(3, availableHeight * base)  // Minimum 3pt instead of 2pt
            bar.frame = NSRect(x: x, y: (bounds.height - h)/2, width: barWidth, height: h)
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
        CATransaction.setAnimationDuration(0.1)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        let minH: CGFloat = 3
        let maxH = bounds.height - 4  // More vertical range
        let now = CFAbsoluteTimeGetCurrent()
        let input = boost(level)
        // Fast attack, slower release for punchy response
        let attack: CGFloat = 0.8  // Faster response
        let release: CGFloat = 0.15  // Slightly faster decay
        if input > displayLevel {
            displayLevel += (input - displayLevel) * attack
        } else {
            displayLevel += (input - displayLevel) * release
        }

        if !barLayers.isEmpty {
            for (i, bar) in barLayers.enumerated() {
                let center = (CGFloat(barCount) - 1) / 2
                let d = abs(CGFloat(i) - center) / center
                // Emphasize center bars a bit, but keep ends responsive
                let shape = 0.7 + 0.3 * (1 - d * d)
                // Per-bar organic noise that scales with level and adds variance
                let seed = noiseSeeds.indices.contains(i) ? noiseSeeds[i] : 0
                let speed: CGFloat = 0.9 + CGFloat(i % 5) * 0.08 // varied per bar
                let wobble = sin(now * Double(12 * speed) + Double(seed))
                let baseGain: CGFloat = 0.95 + CGFloat((i % 7)) * 0.05  // Higher gain
                let noiseScale = 0.40 + 0.80 * displayLevel // More motion
                var amp = displayLevel * baseGain * shape + CGFloat(wobble) * noiseScale
                amp = max(0.15, min(1, amp))  // Higher minimum for more visible bars
                if style == .centerMirror {
                    let falloff = 1 - min(1, abs(CGFloat(i) - center) / center)
                    amp = amp * (0.65 + 0.35 * falloff)
                }
                let h = minH + (maxH - minH) * amp
                var r = bar.frame
                r.size.height = h
                r.origin.y = (bounds.height - h)/2
                bar.frame = r
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
        // Smooth with a slightly faster low-pass for responsiveness
        let alpha: CGFloat = 0.6
        level = level * (1 - alpha) + value * alpha
    }

    private func boost(_ x: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, x))
        // sqrt boosts low/mid levels; mix in a soft knee
        let powBoost = pow(clamped, 0.38) // stronger lift for low/mid
        let knee: CGFloat = 0.1
        return min(1, (powBoost * (1 - knee) + clamped * knee))
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
        layer?.cornerRadius = 10  // Match larger button size
        layer?.masksToBounds = false  // Allow shadow
        // Add subtle shadow
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowOffset = NSSize(width: 0, height: 1)
        layer?.shadowRadius = 2
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
            let scale: CGFloat = isPressed ? 0.88 : (isHovered ? 1.08 : 1.0)
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
            let alpha: CGFloat = isPressed ? 0.35 : (isHovered ? 0.28 : 0.22)
            bg = NSColor.white.withAlphaComponent(alpha)
        case .finish:
            let alpha: CGFloat = isPressed ? 1.0 : (isHovered ? 0.95 : 0.88)
            bg = NSColor.systemRed.withAlphaComponent(alpha)
        }
        bg.setFill()
        let path = NSBezierPath(ovalIn: bounds)
        path.fill()

        // Icon with better contrast
        NSColor.white.setFill()
        NSColor.white.setStroke()
        switch kind {
        case .cancel:
            // Cleaner X icon
            let inset: CGFloat = 6
            let lineWidth: CGFloat = 2.0
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
            // Rounded square stop icon
            let s: CGFloat = 9
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
