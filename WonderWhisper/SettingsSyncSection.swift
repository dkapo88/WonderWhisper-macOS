import SwiftUI

/// Settings → General → iCloud: the opt-in switch, status line and "Sync Now".
struct SettingsSyncSection: View {
  @ObservedObject var sync: SettingsSyncService
  @State private var confirmsRepair = false

  static let recoveryMessage = "This Mac's settings will replace the selected iCloud copies "
    + "on all Macs. Previous copies are backed up next to settings.json before they are replaced."

  var body: some View {
    Section {
      Toggle(isOn: enabledBinding) {
        Text("Sync settings with iCloud")
        Text("Vocabulary, prompts, models, shortcuts and preferences match on every Mac "
          + "signed in to your iCloud account.")
      }
      .disabled(!sync.isICloudAvailable && !sync.isEnabled)

      if !sync.isICloudAvailable {
        StatusBadge(.warning, "iCloud Drive is off on this Mac. Turn it on in System Settings → "
          + "your Apple Account → iCloud → iCloud Drive.")
      } else if sync.isEnabled {
        LabeledContent {
          Button("Sync Now") {
            Task { await sync.syncNow() }
          }
          .disabled(sync.isSyncing)
        } label: {
          statusBadge
        }
      } else if let error = sync.lastError {
        StatusBadge(.error, error)
      }

      if sync.isEnabled, !sync.blockedKeys.isEmpty {
        LabeledContent {
          Button("Repair") {
            confirmsRepair = true
          }
          .disabled(sync.isSyncing)
        } label: {
          StatusBadge(.warning, "Not syncing (unreadable in iCloud): "
            + sync.blockedKeys.joined(separator: ", "))
          Text("Repair uses this Mac's values on all Macs and backs up previous copies.")
        }
      }

      if sync.isEnabled, sync.isOrderingExhausted {
        Text(SettingsSyncService.exhaustedMessage)
          .settingsFootnote()
      }

      if let notice = sync.notice {
        Text(notice)
          .settingsFootnote()
      }
    } header: {
      Text("iCloud")
    } footer: {
      Text("API keys stay in each Mac's Keychain and are never synced, so add them on every Mac. "
        + "Microphones, folders, integration connections and history also stay per Mac. "
        + "Settings are stored in iCloud Drive → WonderWhisper → settings.json.")
        .settingsFootnote()
    }
    .alert(
      "iCloud already has WonderWhisper settings",
      isPresented: choiceBinding
    ) {
      Button("Use iCloud Settings") {
        Task { await sync.resolveFirstEnable(.useCloud) }
      }
      Button("Replace iCloud with This Mac's Settings", role: .destructive) {
        Task { await sync.resolveFirstEnable(.replaceCloud) }
      }
      Button("Cancel", role: .cancel) {
        sync.cancelFirstEnable()
      }
    } message: {
      Text("Use iCloud adopts its settings on this Mac. Replace iCloud uses this Mac's "
        + "settings on all Macs. Previous iCloud copies are backed up next to settings.json.")
    }
    .confirmationDialog("Repair iCloud settings?", isPresented: $confirmsRepair) {
      Button("Use This Mac's Values on All Macs", role: .destructive) {
        Task { await sync.repairBlockedKeys() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(Self.recoveryMessage)
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    if sync.isSyncing {
      StatusBadge(.neutral, "Syncing…")
    } else if let error = sync.lastError {
      StatusBadge(.error, error)
    } else if let lastSyncedAt = sync.lastSyncedAt {
      StatusBadge(.ok, Self.statusText(lastSyncedAt: lastSyncedAt, deviceCount: sync.deviceCount))
    } else {
      StatusBadge(.neutral, "Not synced yet")
    }
  }

  private var enabledBinding: Binding<Bool> {
    Binding(
      get: { sync.isEnabled || sync.isAwaitingFirstEnableChoice },
      set: { enabled in
        Task { await sync.setEnabled(enabled) }
      }
    )
  }

  /// Read-only: every alert button (including Cancel, which Escape triggers) resolves the
  /// choice itself. Clearing it from the setter could race a button's async resolve.
  private var choiceBinding: Binding<Bool> {
    Binding(
      get: { sync.isAwaitingFirstEnableChoice },
      set: { _ in }
    )
  }

  static func statusText(lastSyncedAt: Date, deviceCount: Int?) -> String {
    let when = lastSyncedAt.formatted(.relative(presentation: .named))
    var text = "Synced \(when)"
    if let deviceCount, deviceCount > 0 {
      text += deviceCount == 1 ? " · 1 Mac" : " · \(deviceCount) Macs"
    }
    return text
  }
}
