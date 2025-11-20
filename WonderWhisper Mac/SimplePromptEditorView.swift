import SwiftUI

struct SimplePromptEditorView: View {
  @ObservedObject var vm: DictationViewModel
  let kind: SimplePromptKind

  private var settings: SimplePromptSettings {
    kind == .dictation ? vm.simpleDictation : vm.simpleCommand
  }

  private var headerTitle: String {
    switch kind {
    case .dictation: return "Dictation Rules"
    case .command: return "Command Rules"
    }
  }

  private var summaryText: String {
    switch kind {
    case .dictation:
      return "These rules shape how the Simple Dictation formatter cleans up your transcript before insertion."
    case .command:
      return "Fine-tune Command Mode when transforming selected or OCR’d text."
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Text(headerTitle)
            .font(.title2.weight(.semibold))
          Text(summaryText)
            .font(.callout)
            .foregroundColor(.secondary)
        }

        singleKeySection
        captureSection
        promptHeaderSection
        rulesSection
        promptFooterSection

        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var promptHeaderSection: some View {
    GroupBox("Prompt header") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text("Set the tone and scaffolding for the system prompt before any rules are injected.")
            .font(.caption)
            .foregroundColor(.secondary)
          Spacer()
          Button("Restore default") {
            vm.restoreSimpleHeader(for: kind)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        TextEditor(text: headerBinding)
          .font(.body)
          .frame(minHeight: 140)
          .padding(8)
          .background(
            RoundedRectangle(cornerRadius: 10)
              .fill(Color(nsColor: .textBackgroundColor))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(Color.secondary.opacity(0.2))
          )
      }
      .padding(.top, 4)
    }
  }

  private var captureSection: some View {
    GroupBox("Context inputs") {
      VStack(alignment: .leading, spacing: 12) {
        Text("Simple Mode uses on-device OCR to capture key names and terms from the active window when screen context is enabled.")
          .font(.caption)
          .foregroundColor(.secondary)

        Toggle("Use screen context", isOn: Binding(
          get: { settings.enableScreenContext },
          set: { vm.setSimpleScreenContext($0, for: kind) }
        ))
        .help("When on, WonderWhisper OCRs the active window locally and sends the extracted keywords to the model.")

        Toggle("Use clipboard", isOn: Binding(
          get: { settings.enableClipboardContext },
          set: { vm.setSimpleClipboard($0, for: kind) }
        ))
        .help("Allow the mode to read recently copied text when available.")

        Toggle("Use selected text", isOn: Binding(
          get: { settings.enableSelectedText },
          set: { vm.setSimpleSelectedText($0, for: kind) }
        ))
        .help("Send highlighted text from the current app into the prompt.")
        .disabled(!settings.enableScreenContext && !settings.enableClipboardContext)

        Toggle("Include active text field", isOn: Binding(
          get: { settings.enableActiveTextField },
          set: { vm.setSimpleActiveTextField($0, for: kind) }
        ))
        .help("Also send the full contents of the text field you're typing in, even if nothing is selected.")
      }
      .padding(.top, 4)
    }
  }

  private var singleKeySection: some View {
    GroupBox("Single-key shortcut") {
      VStack(alignment: .leading, spacing: 10) {
        Text(kind == .dictation
             ? "Pick a single modifier key to trigger Simple Dictation on press-and-hold."
             : "Pick a single modifier key to trigger Command Mode.")
          .font(.caption)
          .foregroundColor(.secondary)

        Picker("Activation key", selection: singleKeyBinding) {
          Text("None").tag(HotkeyManager.Selection?.none)
          ForEach(singleKeyOptions, id: \.self) { option in
            Text(option.displayName).tag(Optional(option))
          }
        }
        .labelsHidden()
        .frame(maxWidth: 280)

        if let selection = singleKeyBinding.wrappedValue {
          HStack {
            Text("Current: \(selection.displayName)")
              .font(.caption)
              .foregroundColor(.secondary)
            Spacer()
            Button("Clear") {
              vm.setSimpleSelection(nil, for: kind)
            }
            .buttonStyle(.borderless)
          }
        } else {
          Text("No shortcut assigned — use the dropdown to choose one.")
            .font(.caption)
            .foregroundColor(.secondary)
        }
      }
      .padding(.top, 4)
    }
  }

  private var rulesSection: some View {
    GroupBox("Rule list") {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("The list below feeds directly into the system prompt. Reorder, edit, or remove items to match your workflow.")
            .font(.caption)
            .foregroundColor(.secondary)
          Spacer()
          Button("Restore defaults") {
            vm.restoreSimpleRules(for: kind)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        VStack(alignment: .leading, spacing: 12) {
          ForEach(Array(settings.rules.enumerated()), id: \.element.id) { index, rule in
            ruleCard(index: index, rule: rule)
          }

          Button {
            vm.addSimpleRule(for: kind)
          } label: {
            Label("Add rule", systemImage: "plus")
          }
          .buttonStyle(.bordered)
        }
      }
      .padding(.top, 4)
    }
  }

  private var promptFooterSection: some View {
    GroupBox("Prompt footer") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text("Add final guardrails or context that should always trail the rules.")
            .font(.caption)
            .foregroundColor(.secondary)
          Spacer()
          Button("Restore default") {
            vm.restoreSimpleFooter(for: kind)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        TextEditor(text: footerBinding)
          .font(.body)
          .frame(minHeight: 120)
          .padding(8)
          .background(
            RoundedRectangle(cornerRadius: 10)
              .fill(Color(nsColor: .textBackgroundColor))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 10)
              .stroke(Color.secondary.opacity(0.2))
          )
      }
      .padding(.top, 4)
    }
  }

  private func ruleCard(index: Int, rule: SimplePromptRule) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center) {
        Text("Rule \(index + 1)")
          .font(.callout.weight(.semibold))
        Spacer()
        Button(role: .destructive) {
          vm.removeSimpleRule(kind: kind, ruleID: rule.id)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Delete this rule")
      }

      TextEditor(text: Binding(
        get: {
          let currentRules = kind == .dictation ? vm.simpleDictation.rules : vm.simpleCommand.rules
          return currentRules.first(where: { $0.id == rule.id })?.text ?? ""
        },
        set: { vm.updateSimpleRule(kind: kind, ruleID: rule.id, text: $0) }
      ))
      .font(.body)
      .frame(minHeight: 88)
      .padding(8)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(Color(nsColor: .textBackgroundColor))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color.secondary.opacity(0.2))
      )
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 14)
        .fill(Color(nsColor: .controlBackgroundColor))
    )
  }
}

#Preview {
  SimplePromptEditorView(vm: DictationViewModel(), kind: .dictation)
}

private extension SimplePromptEditorView {
  var singleKeyBinding: Binding<HotkeyManager.Selection?> {
    Binding(
      get: { kind == .dictation ? vm.simpleDictation.selection : vm.simpleCommand.selection },
      set: { vm.setSimpleSelection($0, for: kind) }
    )
  }

  var singleKeyOptions: [HotkeyManager.Selection] {
    HotkeyManager.Selection.allCases
  }

  var includeImageBinding: Binding<Bool> {
    Binding(
      get: { kind == .command ? vm.simpleCommand.includeScreenImage : false },
      set: { vm.setSimpleIncludeImage($0, for: kind) }
    )
  }

  var headerBinding: Binding<String> {
    Binding(
      get: { settings.header },
      set: { vm.updateSimpleHeader(kind: kind, text: $0) }
    )
  }

  var footerBinding: Binding<String> {
    Binding(
      get: { settings.footer },
      set: { vm.updateSimpleFooter(kind: kind, text: $0) }
    )
  }
}
