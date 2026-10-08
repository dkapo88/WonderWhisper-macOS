import SwiftUI

/// Settings → General → History: how many dictations to keep.
struct HistoryRetentionSection: View {
  @ObservedObject var history: HistoryStore

  var body: some View {
    Section {
      NumberStepperRow(
        title: "Keep most recent",
        value: Binding(
          get: { Double(history.maxEntries) },
          set: { history.maxEntries = Int($0) }
        ),
        range: 1...1000,
        step: 10,
        unit: history.maxEntries == 1 ? "entry" : "entries"
      )
    } header: {
      Text("History")
    } footer: {
      Text("Older entries are permanently deleted.")
        .settingsFootnote()
    }
  }
}
