import AppKit
import Combine

/// A floating overlay that displays live streaming transcript text.
/// Black background with white text, positioned at top center of screen.
/// Used for Soniox real-time transcription preview.
@MainActor
final class StreamingTranscriptOverlay {
  private let window: NSWindow
  private let contentView: TranscriptContentView
  private var cancellables: Set<AnyCancellable> = []
  private weak var vm: DictationViewModel?

  // Track visibility state
  private var isVisible: Bool = false

  init(viewModel: DictationViewModel) {
    self.vm = viewModel

    // Create content view
    contentView = TranscriptContentView()

    // Create window
    let size = NSSize(width: 400, height: 80)
    let rect = NSRect(origin: .zero, size: size)
    let w = NSPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.level = .statusBar
    w.hasShadow = true
    w.hidesOnDeactivate = false
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    w.ignoresMouseEvents = true // Click-through
    w.contentView = contentView
    self.window = w

    // Start hidden
    window.alphaValue = 0
    positionAtTopCenter()
    window.orderFrontRegardless()

    // Drive visibility and text directly from the view model, independent of any SwiftUI
    // view lifecycle. Previously these were `.onReceive` modifiers on ContentView, so the
    // overlay silently stopped showing whenever the main window was closed (while the
    // waveform, which self-subscribes like this, kept working). Single predicate so a
    // mid-session engine switch (or a non-live engine) also hides correctly.
    viewModel.$isRecording
      .combineLatest(viewModel.$simpleVoiceEngine)
      .map { isRecording, engine in isRecording && engine.showsLiveTranscript }
      .removeDuplicates()
      .sink { [weak self] shouldShow in
        guard let self else { return }
        if shouldShow { self.show() } else { self.hide() }
      }
      .store(in: &cancellables)

    viewModel.$sonioxPreviewText
      .sink { [weak self] text in
        self?.updateText(text)
      }
      .store(in: &cancellables)

    // Reposition on screen changes (routed through cancellables so it is not leaked)
    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in
        guard let self else { return }
        Task { @MainActor in self.positionAtTopCenter() }
      }
      .store(in: &cancellables)
  }

  /// Show the overlay with animation
  func show() {
    guard !isVisible else { return }
    isVisible = true

    positionAtTopCenter()
    contentView.setText("")

    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.25
      ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1)
      ctx.allowsImplicitAnimation = true
      window.animator().alphaValue = 1
    }
    window.orderFrontRegardless()
  }

  /// Hide the overlay with animation
  func hide() {
    guard isVisible else { return }
    isVisible = false

    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.2
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      ctx.allowsImplicitAnimation = true
      window.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      // Clear stale preview so it can't flash on the next session before the first token.
      self?.contentView.setText("")
    })
  }

  /// Update the displayed transcript text
  func updateText(_ text: String) {
    // Skip redundant work when the preview hasn't changed (provider can re-emit identical text).
    guard contentView.setText(text) else { return }

    // Auto-resize based on content. Use animate:false for live token updates — animating a
    // setFrame on every token is janky and O(n^2) over a sentence; reserve animation for show/hide.
    let newHeight = contentView.preferredHeight()
    if abs(window.frame.height - newHeight) > 10 {
      var frame = window.frame
      let heightDiff = newHeight - frame.height
      frame.size.height = newHeight
      frame.origin.y -= heightDiff // Keep top position stable
      window.setFrame(frame, display: true, animate: false)
    }
  }

  private func positionAtTopCenter() {
    guard let screen = OverlayScreenResolver.activeScreen() else { return }
    let vf = screen.visibleFrame
    let x = screen.frame.midX - window.frame.width / 2
    // Position below menu bar with some padding
    let y = vf.origin.y + vf.height - window.frame.height - 40
    window.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
  }
}

// MARK: - Content View

private final class TranscriptContentView: NSView {
  private let textView: NSTextView
  private let scrollView: NSScrollView
  private var currentText: String = ""
  private var hasRendered = false

  // Built once; identical for every token render.
  private static let textAttributes: [NSAttributedString.Key: Any] = {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 4
    paragraphStyle.alignment = .left
    return [
      .font: NSFont.systemFont(ofSize: 15, weight: .medium),
      .foregroundColor: NSColor.white,
      .paragraphStyle: paragraphStyle
    ]
  }()

  override init(frame frameRect: NSRect) {
    // Create scroll view for text
    scrollView = NSScrollView(frame: .zero)
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false

    // Create text view
    textView = NSTextView(frame: .zero)
    textView.isEditable = false
    textView.isSelectable = false
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 16, height: 12)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = 0

    scrollView.documentView = textView

    super.init(frame: frameRect)

    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
    layer?.cornerRadius = 12
    layer?.cornerCurve = .continuous

    // Subtle border
    layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
    layer?.borderWidth = 0.5

    addSubview(scrollView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    scrollView.frame = bounds
  }

  /// Renders the text. Returns false (and does nothing) when the text is unchanged.
  @discardableResult
  func setText(_ text: String) -> Bool {
    guard !hasRendered || text != currentText else { return false }
    hasRendered = true
    currentText = text

    let displayText = text.isEmpty ? "Listening..." : text
    let attrString = NSAttributedString(string: displayText, attributes: Self.textAttributes)

    textView.textStorage?.setAttributedString(attrString)

    // Scroll to end
    textView.scrollToEndOfDocument(nil)
    return true
  }

  func preferredHeight() -> CGFloat {
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer else {
      return 80
    }

    layoutManager.ensureLayout(for: textContainer)
    let textHeight = layoutManager.usedRect(for: textContainer).height

    // Add padding and constrain
    let totalHeight = textHeight + 24 // 12pt padding top + bottom
    return min(max(60, totalHeight), 200) // Min 60, max 200
  }
}
