import SwiftUI

/// One status line per webhook endpoint for a meeting note, with Retry on failures.
struct MeetingWebhookStatusList: View {
  let records: [MeetingWebhookDeliveryRecord]
  let onRetry: (MeetingWebhookDeliveryRecord) -> Void

  var body: some View {
    if !records.isEmpty {
      TimelineView(.periodic(from: .now, by: 30)) { context in
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
        Button("Retry") { onRetry(record) }
          .buttonStyle(.link)
          .accessibilityLabel("Retry sending to \(record.endpointName)")
      case .sending, .retrying:
        ProgressView().controlSize(.small)
        Text(text)
          .foregroundStyle(.secondary)
      }
    }
    .font(.footnote)
    .lineLimit(2)
  }
}
