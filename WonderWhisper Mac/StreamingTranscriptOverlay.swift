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

    // Reposition on screen changes
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      Task { @MainActor in
        self.positionAtTopCenter()
      }
    }
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

    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.2
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      ctx.allowsImplicitAnimation = true
      window.animator().alphaValue = 0
    }
  }

  /// Update the displayed transcript text
  func updateText(_ text: String) {
    contentView.setText(text)

    // Auto-resize based on content
    let newHeight = contentView.preferredHeight()
    if abs(window.frame.height - newHeight) > 10 {
      var frame = window.frame
      let heightDiff = newHeight - frame.height
      frame.size.height = newHeight
      frame.origin.y -= heightDiff // Keep top position stable
      window.setFrame(frame, display: true, animate: true)
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

  func setText(_ text: String) {
    currentText = text

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 4
    paragraphStyle.alignment = .left

    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 15, weight: .medium),
      .foregroundColor: NSColor.white,
      .paragraphStyle: paragraphStyle
    ]

    let displayText = text.isEmpty ? "Listening..." : text
    let attrString = NSAttributedString(string: displayText, attributes: attributes)

    textView.textStorage?.setAttributedString(attrString)

    // Scroll to end
    textView.scrollToEndOfDocument(nil)
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
