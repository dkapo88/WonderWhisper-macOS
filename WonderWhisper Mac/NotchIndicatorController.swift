import AppKit
import Combine

@MainActor
final class NotchIndicatorController {
    enum Side { case left, right }

    private let window: NSWindow
    private let containerView = CapsuleContainer()
    private var cancellables: Set<AnyCancellable> = []
    private var lastRecording: Bool? = nil
    private weak var vm: DictationViewModel?
    private let side: Side

    // Layout
    private let insetFromNotch: CGFloat = 8
    private let windowSize = NSSize(width: 36, height: 18)

    init(viewModel: DictationViewModel, side: Side = .right) {
        self.vm = viewModel
        self.side = side

        let rect = NSRect(origin: .zero, size: windowSize)
        let w = NSPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .statusBar
        w.hasShadow = false
        w.hidesOnDeactivate = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.contentView = containerView
        self.window = w

        // Start hidden
        window.alphaValue = 0
        updatePosition(animated: false)
        window.orderFrontRegardless()

        // Observe recording state
        viewModel.$isRecording
            .removeDuplicates()
            .sink { [weak self] recording in
                guard let self = self else { return }
                if let prev = self.lastRecording {
                    if recording != prev { self.setRecording(recording, animated: true, playSound: true) }
                } else {
                    // Initial state, update UI without sound
                    self.setRecording(recording, animated: false, playSound: false)
                }
                self.lastRecording = recording
            }
            .store(in: &cancellables)

        // Reposition on screen changes
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.updatePosition(animated: false)
            }
        }
    }

    private func setRecording(_ recording: Bool, animated: Bool, playSound: Bool) {
        if recording {
            updatePosition(animated: false)
            containerView.setActive(true)
            animateIn()
            if playSound { playStartSound() }
        } else {
            containerView.setActive(false)
            animateOut()
            if playSound { playStopSound() }
        }
    }

    private func updatePosition(animated: Bool) {
        guard let screen = OverlayScreenResolver.activeScreen() else { return }
        let vf = screen.visibleFrame
        let xCenter = screen.frame.midX
        var x: CGFloat
        switch side {
        case .right:
            x = xCenter + insetFromNotch
        case .left:
            x = xCenter - insetFromNotch - windowSize.width
        }
        // Place just under the menu bar
        let y = vf.origin.y + vf.height - windowSize.height - 4
        let target = NSRect(x: x.rounded(), y: y.rounded(), width: windowSize.width, height: windowSize.height)
        if animated {
            window.animator().setFrame(target, display: false)
        } else {
            window.setFrame(target, display: false)
        }
    }

    private func animateIn() {
        updatePosition(animated: false)
        let startAlpha = window.alphaValue
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // Slide a few points from the notch side
            var f = window.frame
            switch side {
            case .right: f.origin.x += 10
            case .left: f.origin.x -= 10
            }
            window.setFrame(f, display: false)
            window.animator().alphaValue = 1
            // Animate to final position
            updatePosition(animated: true)
        } completionHandler: {
            // Pulse dot subtly
            self.containerView.startPulse()
        }
        window.alphaValue = startAlpha
        window.orderFrontRegardless()
    }

    private func animateOut() {
        containerView.stopPulse()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // Slide toward notch and fade
            var f = window.frame
            switch side {
            case .right: f.origin.x += 10
            case .left: f.origin.x -= 10
            }
            window.animator().setFrame(f, display: false)
            window.animator().alphaValue = 0
        }
    }

    private func playStartSound() {
        SoundFeedback.playStart()
    }

    private func playStopSound() {
        SoundFeedback.playStop()
    }
}

private final class CapsuleContainer: NSView {
    private let capsule = NSView(frame: .zero)
    private let dot = NSView(frame: .zero)
    private var pulseLayer: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = .clear

        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        capsule.layer?.cornerRadius = 9
        addSubview(capsule)

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 6
        capsule.addSubview(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        capsule.frame = bounds
        let dotSize: CGFloat = 12
        dot.frame = NSRect(x: (bounds.width - dotSize)/2, y: (bounds.height - dotSize)/2, width: dotSize, height: dotSize)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Fit window content
        guard let w = window else { return }
        frame = NSRect(origin: .zero, size: w.frame.size)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func setActive(_ active: Bool) {
        dot.layer?.backgroundColor = (active ? NSColor.systemRed : NSColor.systemGray).cgColor
    }

    func startPulse() {
        stopPulse()
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.15
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
    }

    func stopPulse() {
        dot.layer?.removeAnimation(forKey: "pulse")
    }
}

enum OverlayScreenResolver {
    @MainActor
    static func activeScreen() -> NSScreen? {
        screenContainingFrontmostWindow() ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func screenContainingFrontmostWindow() -> NSScreen? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }

        let pid = frontmost.processIdentifier
        let frontmostWindows = windowInfo.compactMap { info -> CGRect? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerPID.int32Value == pid else {
                return nil
            }

            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { return nil }

            if let alpha = info[kCGWindowAlpha as String] as? NSNumber,
               alpha.doubleValue <= 0 {
                return nil
            }

            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 80,
                  bounds.height >= 60 else {
                return nil
            }
            return bounds
        }

        guard let largestWindow = frontmostWindows.max(by: { $0.area < $1.area }) else {
            return nil
        }
        return screen(containingQuartzFrame: largestWindow)
    }

    private static func screen(containingQuartzFrame frame: CGRect) -> NSScreen? {
        var bestMatch: (screen: NSScreen, area: CGFloat)?

        for screen in NSScreen.screens {
            guard let displayID = displayID(for: screen) else { continue }
            let displayFrame = CGDisplayBounds(displayID)
            let intersection = displayFrame.intersection(frame)
            let area = intersection.isNull ? 0 : intersection.area

            if area > (bestMatch?.area ?? 0) {
                bestMatch = (screen, area)
            }
        }

        guard let bestMatch, bestMatch.area > 0 else { return nil }
        return bestMatch.screen
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map {
            CGDirectDisplayID($0.uint32Value)
        }
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
