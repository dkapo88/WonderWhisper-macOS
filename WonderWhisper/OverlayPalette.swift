import AppKit

/// Colors for the floating surfaces (dictation pill, streaming preview). Kept in one place so
/// the overlays share a palette instead of inline sRGB literals.
enum OverlayPalette {
  /// Near-black capsule body, top to bottom.
  static let pillBodyTop = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 0.97)
  static let pillBodyBottom = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 0.97)
  /// Hairline stroke around dark floating surfaces.
  static let hairline = NSColor.white.withAlphaComponent(0.14)
  static let hairlineWidth: CGFloat = 0.5

  /// Warm signal ramp for the live waveform: amber into a soft coral.
  static let signalRamp: [NSColor] = [
    NSColor(srgbRed: 1.00, green: 0.82, blue: 0.35, alpha: 1),
    NSColor(srgbRed: 1.00, green: 0.58, blue: 0.31, alpha: 1),
    NSColor(srgbRed: 0.99, green: 0.40, blue: 0.42, alpha: 1)
  ]

  /// Primary (finish) control on the pill.
  static func accent(alpha: CGFloat) -> NSColor {
    NSColor(srgbRed: 0.42, green: 0.60, blue: 0.98, alpha: alpha)
  }

  /// Translucent dark backdrop for text overlays that sit on top of other apps.
  static let textBackdrop = NSColor.black.withAlphaComponent(0.72)
  static let textBackdropStroke = NSColor.white.withAlphaComponent(0.18)
}
