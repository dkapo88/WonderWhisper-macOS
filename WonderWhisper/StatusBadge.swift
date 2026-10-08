import SwiftUI

/// The single way the app shows a status ("Saved", "Missing", "Enabled", "Not downloaded").
/// Meaning is carried by the symbol shape as well as the color, so it still reads for
/// colorblind users.
struct StatusBadge: View {
  enum Kind: Equatable {
    case ok
    case warning
    case error
    case neutral

    var symbol: String {
      switch self {
      case .ok: return "checkmark.circle.fill"
      case .warning: return "exclamationmark.triangle.fill"
      case .error: return "xmark.octagon.fill"
      case .neutral: return "minus.circle.fill"
      }
    }

    var tint: Color {
      switch self {
      case .ok: return .green
      case .warning: return .orange
      case .error: return .red
      case .neutral: return .secondary
      }
    }
  }

  let kind: Kind
  let text: String

  init(_ kind: Kind, _ text: String) {
    self.kind = kind
    self.text = text
  }

  var body: some View {
    Label {
      Text(text)
        .foregroundStyle(.secondary)
    } icon: {
      Image(systemName: kind.symbol)
        .foregroundStyle(kind.tint)
    }
    .font(.callout)
    .labelStyle(.titleAndIcon)
    .accessibilityElement(children: .combine)
  }
}

extension StatusBadge {
  /// Status for something that is either present or missing (a key, a model download).
  static func presence(_ isPresent: Bool, present: String, missing: String) -> StatusBadge {
    StatusBadge(isPresent ? .ok : .neutral, isPresent ? present : missing)
  }

  /// Status for an optional connection test result: `nil` means untested.
  static func connection(_ succeeded: Bool?, _ message: String) -> StatusBadge {
    switch succeeded {
    case .some(true): return StatusBadge(.ok, message)
    case .some(false): return StatusBadge(.error, message)
    case .none: return StatusBadge(.neutral, message)
    }
  }
}

#Preview {
  VStack(alignment: .leading) {
    StatusBadge(.ok, "Saved")
    StatusBadge(.warning, "Needs access")
    StatusBadge(.error, "Connection failed")
    StatusBadge(.neutral, "Not downloaded")
  }
  .padding()
}
