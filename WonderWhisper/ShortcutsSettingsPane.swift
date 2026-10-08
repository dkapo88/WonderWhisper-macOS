import SwiftUI

/// Settings → Shortcuts: every activation key in one place, with keys already used by another
/// flow marked and disabled so conflicts can't be created.
struct ShortcutsSettingsPane: View {
  @ObservedObject var vm: DictationViewModel

  var body: some View {
    SettingsPage {
      Section {
        ForEach(ShortcutFlow.allCases) { flow in
          shortcutRow(flow)
        }
      } header: {
        Text("Activation keys")
      } footer: {
        Text("Each key can drive one flow. Keys used elsewhere are labeled and unavailable.")
          .settingsFootnote()
      }

      Section {
        LabeledContent {
          ShortcutRecorderView(shortcut: $vm.pasteShortcut)
        } label: {
          Text("Paste last transcription")
          Text("Inserts your most recent dictation again.")
        }
      } header: {
        Text("Other shortcuts")
      } footer: {
        Text("Toggle Dictation (⌥⌘Space) and Start Meeting (⇧⌘M) are available from the menu "
          + "bar menu.")
          .settingsFootnote()
      }
    }
  }

  private func shortcutRow(_ flow: ShortcutFlow) -> some View {
    Picker(selection: binding(for: flow)) {
      Text("None").tag(HotkeyManager.Selection?.none)
      ForEach(HotkeyManager.Selection.allCases, id: \.self) { option in
        let owner = ShortcutFlow.owner(of: option, in: assignments, excluding: flow)
        Text(owner.map { "\(option.displayName) (\($0.title))" } ?? option.displayName)
          .tag(Optional(option))
          .disabled(owner != nil)
      }
    } label: {
      Text(flow.title)
      Text(flow.detail)
    }
    .accessibilityLabel("\(flow.title) shortcut")
  }

  private var assignments: [ShortcutFlow: HotkeyManager.Selection] {
    var result: [ShortcutFlow: HotkeyManager.Selection] = [:]
    for flow in ShortcutFlow.allCases {
      if let selection = selection(for: flow) {
        result[flow] = selection
      }
    }
    return result
  }

  private func selection(for flow: ShortcutFlow) -> HotkeyManager.Selection? {
    switch flow {
    case .dictation: return vm.simpleDictation.selection
    case .command: return vm.simpleCommand.selection
    case .hermes: return vm.hermesSelection
    case .beeper: return vm.beeperSelection
    case .codex: return vm.codexSelection
    }
  }

  private func binding(for flow: ShortcutFlow) -> Binding<HotkeyManager.Selection?> {
    Binding(
      get: { selection(for: flow) },
      set: { newValue in
        switch flow {
        case .dictation: vm.setSimpleSelection(newValue, for: .dictation)
        case .command: vm.setSimpleSelection(newValue, for: .command)
        case .hermes: vm.setHermesSelection(newValue)
        case .beeper: vm.setBeeperSelection(newValue)
        case .codex: vm.setCodexSelection(newValue)
        }
      }
    )
  }
}
