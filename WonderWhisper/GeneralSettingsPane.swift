import SwiftUI

/// Settings → General: iCloud sync, text insertion and updates.
struct GeneralSettingsPane: View {
  @ObservedObject var vm: DictationViewModel
  @ObservedObject private var updater = UpdaterController.shared

  var body: some View {
    SettingsPage {
      SettingsSyncSection(sync: SettingsSyncService.shared)

      Section {
        Toggle(isOn: $vm.pasteFormatted) {
          Text("Paste as rich text")
          Text("Bullets, numbered lists, and bold/italic arrive as real formatting in apps "
            + "that accept it (Slack, Notes, Mail). Plain text is always included.")
        }
      } header: {
        Text("Text insertion")
      }

      HistoryRetentionSection(history: vm.history)

      Section {
        LabeledContent("Version", value: Self.displayVersion)
        LabeledContent {
          Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        } label: {
          Text("Software update")
          Text("Checked automatically once a day.")
        }
      } header: {
        Text("Updates")
      } footer: {
        Text("Updates are verified against the developer signature before installing, so your "
          + "macOS permissions carry over.")
          .settingsFootnote()
      }
    }
  }

  static var displayVersion: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info?["CFBundleVersion"] as? String ?? ""
    return build.isEmpty || build == short ? short : "\(short) (\(build))"
  }
}
