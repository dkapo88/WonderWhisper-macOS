import SwiftUI

/// Dictation / Command: the mode's options as a short form, then one prompt editor with a
/// Header | Rules | Footer switch instead of three stacked editors.
struct SimplePromptEditorView: View {
  @ObservedObject var vm: DictationViewModel
  let kind: SimplePromptKind
  @State private var templateDraft: PromptTemplateDraft?
  @State private var pendingTemplateDeletion: SimplePromptTemplate?
  @State private var promptPart: PromptPart = .rules

  enum PromptPart: String, CaseIterable, Identifiable {
    case header = "Header"
    case rules = "Rules"
    case footer = "Footer"

    var id: String { rawValue }

    var detail: String {
      switch self {
      case .header: return "Tone and scaffolding that open the system prompt."
      case .rules: return "The rules that shape the output, between the header and footer."
      case .footer: return "Final guardrails that always trail the rules."
      }
    }
  }

  private var settings: SimplePromptSettings {
    kind == .dictation ? vm.simpleDictation : vm.simpleCommand
  }

  var body: some View {
    SettingsPage {
      shortcutSection
      captureSection
      if kind == .dictation {
        promptTemplateSection
      }
      promptSection
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

  // MARK: - Options

  private var shortcutSection: some View {
    Section {
      LabeledContent {
        HStack(spacing: DesignTokens.Spacing.small) {
          Text(settings.selection?.displayName ?? "None")
            .foregroundStyle(.secondary)
          Button("Change…") {
            SettingsRouter.shared.show(.shortcuts)
          }
          .accessibilityLabel("Change \(kind.title) shortcut in Settings")
        }
      } label: {
        Text("Shortcut")
        Text(kind == .dictation
          ? "Hold the key to dictate into the focused app."
          : "Press the key to transform selected or on-screen text.")
      }
    } header: {
      Text("Activation")
    }
  }

  private var captureSection: some View {
    Section {
      Toggle(isOn: Binding(
        get: { settings.enableScreenContext },
        set: { vm.setSimpleScreenContext($0, for: kind) }
      )) {
        Text("Screen context")
        Text("OCR the active window on-device and send key terms to the model.")
      }

      Toggle(isOn: Binding(
        get: { settings.enableClipboardContext },
        set: { vm.setSimpleClipboard($0, for: kind) }
      )) {
        Text("Clipboard")
        Text("Include recently copied text when available.")
      }

      Toggle(isOn: Binding(
        get: { settings.enableSelectedText },
        set: { vm.setSimpleSelectedText($0, for: kind) }
      )) {
        Text("Selected text")
        Text("Send highlighted text from the current app. Needs screen context or clipboard.")
      }
      .disabled(!settings.enableScreenContext && !settings.enableClipboardContext)

      Toggle(isOn: Binding(
        get: { settings.enableActiveTextField },
        set: { vm.setSimpleActiveTextField($0, for: kind) }
      )) {
        Text("Active text field")
        Text("Send the whole field you're typing in, even with nothing selected.")
      }
    } header: {
      Text("Context inputs")
    }
  }

  private var promptTemplateSection: some View {
    Section {
      Picker(selection: Binding<UUID?>(
        get: { vm.selectedDictationPromptTemplateID },
        set: { newValue in
          guard let id = newValue else {
            vm.selectedDictationPromptTemplateID = nil
            return
          }
          vm.applyDictationPromptTemplate(id: id)
        }
      )) {
        Text("None").tag(UUID?.none)
        ForEach(vm.dictationPromptTemplates) { template in
          Text(template.name).tag(Optional(template.id))
        }
      } label: {
        Text("Template")
        Text(templateDetail)
      }

      HStack(spacing: DesignTokens.Spacing.xSmall) {
        Spacer()
        Button("Save as Template…") {
          templateDraft = PromptTemplateDraft(
            mode: .save,
            title: "Save Template",
            name: suggestedTemplateName,
            rules: settings.rules,
            footer: settings.footer
          )
        }
        Button("Edit…") {
          guard let template = selectedEditableTemplate else { return }
          templateDraft = PromptTemplateDraft(
            mode: .edit(template.id),
            title: "Edit Template",
            name: template.name,
            rules: template.rules,
            footer: template.footer
          )
        }
        .disabled(selectedEditableTemplate == nil)
        .accessibilityLabel("Edit template")
        Button("Delete…", role: .destructive) {
          pendingTemplateDeletion = selectedEditableTemplate
        }
        .disabled(selectedEditableTemplate == nil)
        .accessibilityLabel("Delete template")
      }
    } header: {
      Text("Prompt template")
    }
  }

  private var templateDetail: String {
    guard let selected = selectedTemplate else {
      return "Choosing a template replaces the rules and footer."
    }
    return selected.isBuiltIn
      ? "Built-in. Save it as a template to customize."
      : "Custom template."
  }

  // MARK: - Prompt

  private var promptSection: some View {
    Section {
      TextEditor(text: binding(for: promptPart))
        .font(.body.monospaced())
        .scrollContentBackground(.hidden)
        .frame(minHeight: 380)
        .accessibilityLabel("\(kind.title) prompt \(promptPart.rawValue.lowercased())")
    } header: {
      HStack(spacing: DesignTokens.Spacing.small) {
        Text("Prompt")
        Spacer()
        Picker("Prompt part", selection: $promptPart) {
          ForEach(PromptPart.allCases) { part in
            Text(part.rawValue).tag(part)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Prompt part")
      }
    } footer: {
      HStack(alignment: .firstTextBaseline) {
        Text(promptPart.detail)
          .settingsFootnote()
        Spacer()
        Button(promptPart == .rules ? "Restore Default Rules" : "Restore Default") {
          restoreDefault(promptPart)
        }
        .controlSize(.small)
      }
    }
  }

  private func binding(for part: PromptPart) -> Binding<String> {
    switch part {
    case .header: return headerBinding
    case .rules: return rulesBinding
    case .footer: return footerBinding
    }
  }

  private func restoreDefault(_ part: PromptPart) {
    switch part {
    case .header: vm.restoreSimpleHeader(for: kind)
    case .rules: vm.restoreSimpleRules(for: kind)
    case .footer: vm.restoreSimpleFooter(for: kind)
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
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
        TextField("Template name", text: $name)
          .textFieldStyle(.roundedBorder)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Prompt body")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
        TextEditor(text: $rules)
          .font(.body)
          .frame(minHeight: 220)
          .padding(8)
          .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
              .fill(Color(nsColor: .textBackgroundColor))
          )
          .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
              .stroke(Color.secondary.opacity(0.2))
          )
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Footer")
          .font(.callout.weight(.semibold))
          .foregroundStyle(.secondary)
        TextEditor(text: $footer)
          .font(.body)
          .frame(minHeight: 120)
          .padding(8)
          .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
              .fill(Color(nsColor: .textBackgroundColor))
          )
          .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
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
