import Foundation
import SwiftUI

// Presentation-only pieces of the meeting companion. They take plain values instead of
// `MeetingCoordinator`, so they can be rendered in isolation and stay cheap to diff.

enum MeetingCompanionStyle {
  static let microphoneTint = Color.blue
  static let remoteTint = Color.purple
  /// One colour per voice on the call, in the order they were first heard.
  static let speakerTints: [Color] = [
    .purple, .orange, .teal, .pink, .green, .indigo, .brown, .mint,
  ]

  static func tint(for speaker: MeetingSpeakerKey, in directory: MeetingSpeakerDirectory) -> Color {
    guard let index = directory.colorIndex(for: speaker) else { return microphoneTint }
    return speakerTints[index % speakerTints.count]
  }

  static func tint(for source: MeetingAudioSource) -> Color {
    source == .microphone ? microphoneTint : remoteTint
  }
  static let recordingTint = Color(red: 1, green: 0.27, blue: 0.23)

  static func elapsed(since start: Date, now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(start).rounded(.down)))
    let hours = total / 3_600
    let minutes = (total % 3_600) / 60
    let seconds = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
      : String(format: "%d:%02d", minutes, seconds)
  }
}

/// Red dot that breathes while recording. Holds still under Reduce Motion.
struct MeetingRecordingDot: View {
  var size: CGFloat = 7
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dimmed = false

  var body: some View {
    Circle()
      .fill(MeetingCompanionStyle.recordingTint)
      .frame(width: size, height: size)
      .opacity(dimmed ? 0.35 : 1)
      .background {
        Circle()
          .fill(MeetingCompanionStyle.recordingTint.opacity(0.35))
          .frame(width: size * 2, height: size * 2)
          .blur(radius: 3)
          .opacity(dimmed ? 0 : 0.8)
      }
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
          dimmed = true
        }
      }
  }
}

/// Four thin bars that follow the loudest live source.
struct MeetingLevelBars: View {
  let level: CGFloat
  var maxHeight: CGFloat = 14
  private let multipliers: [CGFloat] = [0.55, 1, 0.75, 0.4]

  var body: some View {
    HStack(alignment: .center, spacing: 2) {
      ForEach(multipliers.indices, id: \.self) { index in
        Capsule()
          .frame(
            width: 2.5,
            height: 3 + (maxHeight - 3) * min(1, max(0, level)) * multipliers[index]
          )
      }
    }
    .frame(height: maxHeight)
    .animation(.easeOut(duration: 0.12), value: level)
  }
}

/// The minimized companion: a dark capsule with the recording dot, elapsed time and level.
struct MeetingRecordingPill: View {
  static let size = CGSize(width: 124, height: 36)

  let startedAt: Date
  let level: CGFloat

  var body: some View {
    HStack(spacing: 8) {
      MeetingRecordingDot()
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(MeetingCompanionStyle.elapsed(since: startedAt, now: context.date))
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
          .fixedSize()
      }
      Spacer(minLength: 0)
      MeetingLevelBars(level: level)
        .foregroundStyle(.white.opacity(0.85))
    }
    .padding(.leading, 13)
    .padding(.trailing, 14)
    .frame(width: Self.size.width, height: Self.size.height)
    .background {
      Capsule(style: .continuous)
        .fill(Color(white: 0.1).opacity(0.94))
    }
    .overlay {
      Capsule(style: .continuous)
        .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
    }
    .environment(\.colorScheme, .dark)
  }
}

/// Title, live timer and the two session actions. The whole bar is the drag handle.
struct MeetingCompanionHeader: View {
  let title: String
  let startedAt: Date
  let isStopping: Bool
  let onMinimize: () -> Void
  let onStop: () -> Void
  var isMicrophoneMuted = false
  /// Shows the microphone mute button when set.
  var onToggleMicrophoneMute: (() -> Void)?

  private func statusText(now: Date) -> String {
    if isStopping { return "Saving…" }
    let elapsed = MeetingCompanionStyle.elapsed(since: startedAt, now: now)
    return isMicrophoneMuted ? "Recording · \(elapsed) · Mic muted" : "Recording · \(elapsed)"
  }

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 10) {
        MeetingRecordingDot()
          .padding(.leading, 2)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
          TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(statusText(now: context.date))
              .font(.system(size: 11))
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
        }
      }
      // Let presses fall through to the drag handle behind the header.
      .allowsHitTesting(false)
      Spacer(minLength: 8)
      if let onToggleMicrophoneMute {
        Button(action: onToggleMicrophoneMute) {
          Image(systemName: isMicrophoneMuted ? "mic.slash.fill" : "mic.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isMicrophoneMuted ? MeetingCompanionStyle.recordingTint : .secondary)
            .frame(width: 26, height: 26)
            .background(
              isMicrophoneMuted
                ? MeetingCompanionStyle.recordingTint.opacity(0.16)
                : Color.primary.opacity(0.06),
              in: Circle()
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isStopping)
        .help(isMicrophoneMuted
          ? "Unmute: transcribe your microphone again"
          : "Mute: stop transcribing your microphone (audio is still saved)")
        .accessibilityLabel(isMicrophoneMuted ? "Unmute microphone" : "Mute microphone")
      }
      Button(action: onMinimize) {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 26, height: 26)
          .background(Color.primary.opacity(0.06), in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help("Collapse to pill")
      Button(action: onStop) {
        Text(isStopping ? "Stopping" : "Stop")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .frame(height: 26)
          .background(MeetingCompanionStyle.recordingTint, in: Capsule(style: .continuous))
          .contentShape(Capsule(style: .continuous))
          .fixedSize()
      }
      .buttonStyle(.plain)
      .disabled(isStopping)
      .opacity(isStopping ? 0.6 : 1)
      .help("Stop and save the meeting")
    }
    .padding(.horizontal, 14)
    .padding(.top, 12)
    .padding(.bottom, 10)
  }
}

enum MeetingOverlayTab: Hashable, CaseIterable {
  case transcript
  case context
  case notes

  var title: String {
    switch self {
    case .transcript: return "Transcript"
    case .context: return "Context"
    case .notes: return "Notes"
    }
  }
}

/// The Transcript / Context / Notes selector, deliberately holding no reference to
/// `MeetingCoordinator`.
///
/// Inline in `MeetingOverlayView.body`, this control was bound straight to `@State` via
/// `$selectedTab`. A `Binding` carries closures, so SwiftUI could never prove the Picker
/// unchanged, and every one of `MeetingCoordinator`'s 43 published properties re-entered the
/// AppKit `NSSegmentedControl` sizing path behind `.pickerStyle(.segmented)`, measured at
/// roughly twice the CPU per publish of having no tab control at all. Extracted here, the view
/// value is a tab plus a callback and compares equal across publishes, so the subtree
/// short-circuits. `.equatable()` at the call site makes that short-circuit explicit and pinned
/// by test rather than dependent on SwiftUI's implicit view comparison. The control is now
/// drawn in SwiftUI, so there is no AppKit sizing path left either.
struct MeetingOverlayTabPicker: View, Equatable {
  static let maxWidth: CGFloat = 320

  let selection: MeetingOverlayTab
  let onSelect: (MeetingOverlayTab) -> Void
  @Namespace private var selectionNamespace

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.selection == rhs.selection
  }

  var body: some View {
    HStack(spacing: 2) {
      ForEach(MeetingOverlayTab.allCases, id: \.self) { tab in
        Button {
          withAnimation(.snappy(duration: 0.22)) { onSelect(tab) }
        } label: {
          Text(tab.title)
            .font(.system(size: 12, weight: tab == selection ? .semibold : .medium))
            .foregroundStyle(tab == selection ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background {
              if tab == selection {
                Capsule(style: .continuous)
                  .fill(Color.primary.opacity(0.09))
                  .matchedGeometryEffect(id: "selection", in: selectionNamespace)
              }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == selection ? .isSelected : [])
      }
    }
    .padding(2)
    .background(Color.primary.opacity(0.04), in: Capsule(style: .continuous))
    .frame(maxWidth: Self.maxWidth)
  }
}

/// One speaker turn: tinted speaker name, quiet timestamp, then the words.
struct MeetingSpeakerTurnView: View {
  let speaker: String
  let timestamp: String
  let text: String
  let tint: Color
  var isLive = false

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Circle()
          .fill(tint)
          .frame(width: 6, height: 6)
        Text(speaker)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(tint)
        Text(timestamp)
          .font(.system(size: 11))
          .monospacedDigit()
          .foregroundStyle(.tertiary)
      }
      Text(text)
        .font(.system(size: 13))
        .lineSpacing(2)
        .foregroundStyle(isLive ? .secondary : .primary)
        .textSelection(.enabled)
        .padding(.leading, 12)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A short status line ("Searching your vault…") with an optional spinner.
struct MeetingCompanionStatusRow: View {
  let text: String
  var isBusy = false

  var body: some View {
    HStack(spacing: 7) {
      if isBusy {
        ProgressView()
          .controlSize(.mini)
      } else {
        Image(systemName: "waveform")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
      }
      Text(text)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct MeetingContextChip: Identifiable {
  let id: UUID
  let title: String
  let path: String
}

/// A context card: the topic heard in the meeting, what the vault says about it, and the notes
/// it came from.
struct MeetingContextCardView: View {
  let term: String
  let summary: String
  let chips: [MeetingContextChip]
  let hasTicket: Bool
  let onOpenTicket: () -> Void
  let onOpenChip: (MeetingContextChip) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(term)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(2)
        Spacer(minLength: 6)
        if hasTicket {
          Button(action: onOpenTicket) {
            Label("Ticket", systemImage: "arrow.up.right")
              .labelStyle(.titleAndIcon)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
              .frame(height: 20)
              .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
              .contentShape(Capsule(style: .continuous))
          }
          .buttonStyle(.plain)
          .help("Open the linked ticket")
        }
      }
      Text(summary)
        .font(.system(size: 12.5))
        .lineSpacing(1.5)
        .foregroundStyle(.primary.opacity(0.82))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      if !chips.isEmpty {
        MeetingChipFlowLayout(spacing: 5) {
          ForEach(chips) { chip in
            Button { onOpenChip(chip) } label: {
              HStack(spacing: 4) {
                Image(systemName: "doc.text")
                  .font(.system(size: 10))
                  .foregroundStyle(.tertiary)
                Text(chip.title)
                  .font(.system(size: 11))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              .padding(.horizontal, 8)
              .frame(height: 22)
              .frame(maxWidth: 170)
              .fixedSize(horizontal: true, vertical: false)
              .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
              .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .help(chip.path)
          }
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.primary.opacity(0.035),
      in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
    }
  }
}

/// Compact empty state that fits a 300pt-wide panel, unlike `ContentUnavailableView`.
struct MeetingCompanionEmptyState: View {
  let systemImage: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.system(size: 20, weight: .light))
        .foregroundStyle(.tertiary)
        .padding(.bottom, 2)
      Text(title)
        .font(.system(size: 13, weight: .semibold))
      Text(message)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: 240)
    .frame(maxWidth: .infinity)
    .padding(.top, 36)
  }
}

/// Lays chips out left to right and wraps to a new row when the card runs out of width.
struct MeetingChipFlowLayout: Layout {
  var spacing: CGFloat = 5

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map { $0.width }.max() ?? 0
    let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if proposedWidth > width, !current.indices.isEmpty {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
