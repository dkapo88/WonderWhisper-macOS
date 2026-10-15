import SwiftUI

/// One status line per webhook endpoint for a meeting note, with Retry on failures (which
/// resends only the missing parts of a split send).
struct MeetingWebhookStatusList: View {
  let records: [MeetingWebhookDeliveryRecord]
  let onRetry: (MeetingWebhookDeliveryRecord) -> Void

  /// Countdowns ("next in 7s") refresh every second; otherwise every 30 seconds is enough.
  private var refreshInterval: TimeInterval {
    records.contains { $0.nextAttemptAt != nil && $0.state.isInFlight } ? 1 : 30
  }

  var body: some View {
    if !records.isEmpty {
      TimelineView(.periodic(from: .now, by: refreshInterval)) { context in
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxSmall) {
          ForEach(records) { record in
            row(record, now: context.date)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func row(_ record: MeetingWebhookDeliveryRecord, now: Date) -> some View {
    let text = MeetingWebhookStatusFormatter.text(for: record, now: now)
    HStack(spacing: DesignTokens.Spacing.xSmall) {
      switch record.state {
      case .delivered:
        StatusBadge(.ok, text)
      case .failed:
        StatusBadge(.error, text)
        Button(record.supportsPartialResend ? "Resend Missing Parts" : "Retry") {
          onRetry(record)
        }
        .buttonStyle(.link)
        .accessibilityLabel("Retry sending to \(record.endpointName)")
      case .queued, .sending, .retrying:
        ProgressView().controlSize(.small)
        Text(text)
          .foregroundStyle(.secondary)
      }
    }
    .font(.footnote)
    .lineLimit(2)
  }
}
