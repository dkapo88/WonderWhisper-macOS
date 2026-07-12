import SwiftUI

struct SimplePromptEditorView: View {
  @ObservedObject var vm: DictationViewModel
  let kind: SimplePromptKind
  @State private var templateDraft: PromptTemplateDraft?
  @State private var pendingTemplateDeletion: SimplePromptTemplate?

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
        promptTemplateSection
        promptHeaderSection
        rulesSection
        promptFooterSection

        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .sheet(item: $templateDraft) { draft in
      PromptTemplateEditorSheet(draft: draft) { name, rules, footer in
        switch draft.mode {
        case .save:
          vm.saveCurrentDictationPromptTemplate(named: name)
        case .edit(let id):
          vm.updateDictationPromptTemplate(id: id, name: name, rules: rules, footer: footer)
        }
      }
    }
    .confirmationDialog(
      "Delete template?",
      isPresented: Binding(
        get: { pendingTemplateDeletion != nil },
        set: { if !$0 { pendingTemplateDeletion = nil } }
      )
    ) {
      if let template = pendingTemplateDeletion {
        Button("Delete \(template.name)", role: .destructive) {
          vm.deleteDictationPromptTemplate(id: template.id)
          pendingTemplateDeletion = nil
        }
      }
      Button("Cancel", role: .cancel) {
        pendingTemplateDeletion = nil
      }
    }
  }

  private var promptTemplateSection: some View {
    Group {
      if kind == .dictation {
        GroupBox("Prompt templates") {
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Picker("Template", selection: Binding<UUID?>(
                get: { vm.selectedDictationPromptTemplateID },
                set: { newValue in
                  guard let id = newValue else {
                    vm.selectedDictationPromptTemplateID = nil
                    return
                  }
                  vm.applyDictationPromptTemplate(id: id)
                }
              )) {
                Text("Choose template").tag(UUID?.none)
                ForEach(vm.dictationPromptTemplates) { template in
                  Text(template.name).tag(Optional(template.id))
                }
              }
              .frame(maxWidth: 360)

              Spacer()

              Button {
                templateDraft = PromptTemplateDraft(
                  mode: .save,
                  title: "Save Template",
                  name: suggestedTemplateName,
                  rules: settings.rules,
                  footer: settings.footer
                )
              } label: {
                Label("Save Template", systemImage: "plus")
              }
              .controlSize(.small)

              Button {
                guard let template = selectedEditableTemplate else { return }
                templateDraft = PromptTemplateDraft(
                  mode: .edit(template.id),
                  title: "Edit Template",
                  name: template.name,
                  rules: template.rules,
                  footer: template.footer
                )
              } label: {
                Label("Edit Template", systemImage: "pencil")
              }
              .controlSize(.small)
              .disabled(selectedEditableTemplate == nil)

              Button(role: .destructive) {
                pendingTemplateDeletion = selectedEditableTemplate
              } label: {
                Label("Delete Template", systemImage: "trash")
              }
              .controlSize(.small)
              .disabled(selectedEditableTemplate == nil)
            }

            if let selected = selectedTemplate {
              Text(selected.isBuiltIn
                   ? "Built-in templates can be applied or saved as a new custom template."
                   : "Custom template selected.")
                .font(.caption)
                .foregroundColor(.secondary)
            } else {
              Text("Selecting a template replaces the current prompt body and footer.")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
          .padding(.top, 4)
        }
      }
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
             ? "Pick a single key to trigger Simple Dictation on press-and-hold."
             : "Pick a single key to trigger Command Mode.")
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
    GroupBox("Rules") {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          Text("These rules feed directly into the system prompt between the header and footer. Edit freely to match your workflow.")
            .font(.caption)
            .foregroundColor(.secondary)
          Spacer()
          Button("Restore defaults") {
            vm.restoreSimpleRules(for: kind)
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        TextEditor(text: rulesBinding)
          .font(.body)
          .frame(minHeight: 300)
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

}

#Preview {
  SimplePromptEditorView(vm: DictationViewModel(), kind: .dictation)
}

private struct PromptTemplateDraft: Identifiable {
  enum Mode {
    case save
    case edit(UUID)
  }

  let id = UUID()
  let mode: Mode
  let title: String
  let name: String
  let rules: String
  let footer: String
}

private struct PromptTemplateEditorSheet: View {
  let draft: PromptTemplateDraft
  let onSave: (String, String, String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var rules: String
  @State private var footer: String

  init(draft: PromptTemplateDraft, onSave: @escaping (String, String, String) -> Void) {
    self.draft = draft
    self.onSave = onSave
    _name = State(initialValue: draft.name)
    _rules = State(initialValue: draft.rules)
    _footer = State(initialValue: draft.footer)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(draft.title)
        .font(.title3.weight(.semibold))

      VStack(alignment: .leading, spacing: 6) {
        Text("Name")
          .font(.caption.weight(.semibold))
          .foregroundColor(.secondary)
        TextField("Template name", text: $name)
          .textFieldStyle(.roundedBorder)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Prompt body")
          .font(.caption.weight(.semibold))
          .foregroundColor(.secondary)
        TextEditor(text: $rules)
          .font(.body)
          .frame(minHeight: 220)
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

      VStack(alignment: .leading, spacing: 6) {
        Text("Footer")
          .font(.caption.weight(.semibold))
          .foregroundColor(.secondary)
        TextEditor(text: $footer)
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

      HStack {
        Spacer()
        Button("Cancel") {
          dismiss()
        }
        Button("Save") {
          onSave(name, rules, footer)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(24)
    .frame(width: 680, height: 640)
  }
}

private extension SimplePromptEditorView {
  var selectedTemplate: SimplePromptTemplate? {
    guard let id = vm.selectedDictationPromptTemplateID else { return nil }
    return vm.dictationPromptTemplates.first(where: { $0.id == id })
  }

  var selectedEditableTemplate: SimplePromptTemplate? {
    guard let template = selectedTemplate, !template.isBuiltIn else { return nil }
    return template
  }

  var suggestedTemplateName: String {
    var counter = vm.customDictationPromptTemplates.count + 1
    var candidate = "Custom template \(counter)"
    let existing = Set(vm.dictationPromptTemplates.map { $0.name.lowercased() })
    while existing.contains(candidate.lowercased()) {
      counter += 1
      candidate = "Custom template \(counter)"
    }
    return candidate
  }

  var singleKeyBinding: Binding<HotkeyManager.Selection?> {
    Binding(
      get: { kind == .dictation ? vm.simpleDictation.selection : vm.simpleCommand.selection },
      set: { vm.setSimpleSelection($0, for: kind) }
    )
  }

  var singleKeyOptions: [HotkeyManager.Selection] {
    HotkeyManager.Selection.allCases
  }

  var headerBinding: Binding<String> {
    Binding(
      get: { settings.header },
      set: { vm.updateSimpleHeader(kind: kind, text: $0) }
    )
  }

  var rulesBinding: Binding<String> {
    Binding(
      get: { settings.rules },
      set: { vm.updateSimpleRules(kind: kind, text: $0) }
    )
  }

  var footerBinding: Binding<String> {
    Binding(
      get: { settings.footer },
      set: { vm.updateSimpleFooter(kind: kind, text: $0) }
    )
  }
}
