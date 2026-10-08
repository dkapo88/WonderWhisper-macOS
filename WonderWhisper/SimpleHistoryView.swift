import AppKit
import SwiftUI

/// History: a plain list of recent dictations with a detail pane. Retention lives in
/// Settings → General.
struct SimpleHistoryView: View {
  @ObservedObject var vm: DictationViewModel

  var body: some View {
    HistoryContent(vm: vm, history: vm.history)
  }
}

private struct HistoryContent: View {
  let vm: DictationViewModel
  @ObservedObject var history: HistoryStore
  @State private var selectedEntryID: UUID?
  @State private var selectedEntryForDebug: HistoryEntry?

  private var visibleEntries: [HistoryEntry] {
    history.entries.filter { !Self.isEmpty($0) }
  }

  private var hiddenEmptyCount: Int {
    history.entries.count - visibleEntries.count
  }

  var body: some View {
    Group {
      if visibleEntries.isEmpty {
        ContentUnavailableView(
          "No history yet",
          systemImage: "clock",
          description: Text("Dictations and commands appear here after you run them.")
        )
      } else {
        HSplitView {
          list
            .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
          detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .sheet(item: $selectedEntryForDebug) { entry in
      PromptDebugView(entry: entry)
    }
    .onAppear {
      if selectedEntryID == nil {
        selectedEntryID = visibleEntries.first?.id
      }
    }
  }

  private var list: some View {
    List(selection: $selectedEntryID) {
      Section {
        ForEach(visibleEntries, id: \.id) { entry in
          HistoryRow(entry: entry, preview: Self.preview(for: entry))
            .tag(entry.id)
            .contextMenu { contextMenu(for: entry) }
        }
      } footer: {
        if hiddenEmptyCount > 0 {
          Text("\(hiddenEmptyCount) empty \(hiddenEmptyCount == 1 ? "recording" : "recordings") hidden")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .listStyle(.inset)
  }

  @ViewBuilder
  private func contextMenu(for entry: HistoryEntry) -> some View {
    Button("Copy Text", systemImage: "doc.on.doc") {
      copy(entry.output.isEmpty ? entry.transcript : entry.output)
    }
    Button("Reprocess", systemImage: "arrow.clockwise") {
      Task { await vm.reprocessHistoryEntry(entry) }
    }
    if entry.audioFilename != nil {
      Button("Show Audio in Finder", systemImage: "waveform") {
        history.revealInFinder(entry: entry)
      }
    }
  }

  @ViewBuilder
  private var detail: some View {
    if let entry = visibleEntries.first(where: { $0.id == selectedEntryID }) {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
          header(for: entry)

          if !entry.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textBlock(title: "Output", text: entry.output) {
              Button("Copy", systemImage: "doc.on.doc") { copy(entry.output) }
                .accessibilityLabel("Copy output")
            }
          }

          textBlock(title: "Transcript", text: entry.transcript) {
            HStack(spacing: DesignTokens.Spacing.xSmall) {
              if entry.audioFilename != nil {
                Button("Show Audio", systemImage: "waveform") {
                  history.revealInFinder(entry: entry)
                }
              }
              Button("Copy", systemImage: "doc.on.doc") { copy(entry.transcript) }
                .accessibilityLabel("Copy transcript")
            }
          }
        }
        .padding(DesignTokens.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      ContentUnavailableView(
        "No entry selected",
        systemImage: "clock",
        description: Text("Select an entry to see its transcript and output.")
      )
    }
  }

  private func header(for entry: HistoryEntry) -> some View {
    HStack(alignment: .center, spacing: DesignTokens.Spacing.small) {
      AppIconView(bundleID: entry.bundleID, size: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.appName ?? "Unknown app")
          .font(.title3.weight(.semibold))
        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        Task { await vm.reprocessHistoryEntry(entry) }
      } label: {
        Label("Reprocess", systemImage: "arrow.clockwise")
      }
      .help("Run this recording through the current model and prompt again")
      if entry.llmSystemMessage != nil || entry.llmUserMessage != nil {
        Button {
          selectedEntryForDebug = entry
        } label: {
          Label("View Prompt", systemImage: "terminal")
        }
      }
    }
  }

  private func textBlock<Actions: View>(
    title: String,
    text: String,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        actions()
          .controlSize(.small)
      }
      Text(text.isEmpty ? "Nothing was captured." : text)
        .foregroundStyle(text.isEmpty ? .secondary : .primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.small)
        .background(
          .quaternary.opacity(0.45),
          in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
        )
    }
  }

  static func isEmpty(_ entry: HistoryEntry) -> Bool {
    entry.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && entry.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func preview(for entry: HistoryEntry) -> String {
    let candidate = entry.output.isEmpty ? entry.transcript : entry.output
    return candidate
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

private struct HistoryRow: View {
  let entry: HistoryEntry
  let preview: String

  var body: some View {
    HStack(alignment: .top, spacing: DesignTokens.Spacing.xSmall) {
      AppIconView(bundleID: entry.bundleID, size: 20)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline) {
          Text(entry.appName ?? "Unknown app")
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Spacer(minLength: DesignTokens.Spacing.xxSmall)
          Text(entry.date.formatted(date: .omitted, time: .shortened))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Text(preview)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.vertical, DesignTokens.Spacing.xxSmall)
    .accessibilityElement(children: .combine)
  }
}

/// The icon of the app a dictation went into, or a neutral placeholder.
private struct AppIconView: View {
  let bundleID: String?
  let size: CGFloat

  var body: some View {
    Group {
      if let bundleID,
         let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
          .resizable()
      } else {
        Image(systemName: "app.dashed")
          .resizable()
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

private struct PromptDebugView: View {
  let entry: HistoryEntry
  @Environment(\.dismiss) var dismiss

  @State private var selectedTab: DebugTab = .prompts

  enum DebugTab: String, CaseIterable {
    case prompts = "Prompts"
    case context = "Context"
    case performance = "Performance"
    case json = "Raw JSON"
  }

  var body: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Prompt Debug Information")
          .font(.headline)
        Spacer()
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close")
      }
      .padding(16)
      .background(Color(nsColor: .controlBackgroundColor))
      .overlay(
        Divider(),
        alignment: .bottom
      )

      // Tab selector
      Picker("Debug Tab", selection: $selectedTab) {
        ForEach(DebugTab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(12)

      // Content
      TabView(selection: $selectedTab) {
        promptsTab
          .tag(DebugTab.prompts)
        contextTab
          .tag(DebugTab.context)
        performanceTab
          .tag(DebugTab.performance)
        jsonTab
          .tag(DebugTab.json)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(width: 900, height: 700)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  // MARK: - Prompts Tab
  private var promptsTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let systemMsg = entry.llmSystemMessage, !systemMsg.isEmpty {
          debugSection(
            title: "System Message",
            content: systemMsg,
            copyAction: { copy(systemMsg) }
          )
        } else {
          Text("No system message available")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
        }

        Divider()

        if let userMsg = entry.llmUserMessage, !userMsg.isEmpty {
          debugSection(
            title: "User Message",
            content: userMsg,
            copyAction: { copy(userMsg) }
          )
        } else {
          Text("No user message available")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(12)
        }
      }
      .padding(16)
    }
  }

  // MARK: - Context Tab
  private var contextTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        // App info
        GroupBox("Application") {
          VStack(alignment: .leading, spacing: 6) {
            labeledValue("App Name", entry.appName ?? "Unknown")
            if let bundleID = entry.bundleID {
              labeledValue("Bundle ID", bundleID)
            }
          }
          .padding(8)
        }

        // Selected text
        if let selectedText = entry.selectedText, !selectedText.isEmpty {
          GroupBox("Selected Text") {
            VStack(alignment: .leading, spacing: 6) {
              Text(selectedText)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(10)
              HStack {
                Spacer()
                Button { copy(selectedText) } label: {
                  Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
              }
            }
            .padding(8)
          }
        }

        // Screen context
        if let screenContext = entry.screenContext, !screenContext.isEmpty {
          GroupBox("Screen Context") {
            VStack(alignment: .leading, spacing: 6) {
              if let method = entry.screenContextMethod {
                Text("Method: \(method)")
                  .font(.callout)
                  .foregroundColor(.secondary)
              }
              Text(screenContext)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(10)
              HStack {
                Spacer()
                Button { copy(screenContext) } label: {
                  Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
              }
            }
            .padding(8)
          }
        }

        // Screen image info
        if let filename = entry.screenImageFilename {
          GroupBox("Screen Image") {
            VStack(alignment: .leading, spacing: 6) {
              labeledValue("Filename", filename)
              if let mimeType = entry.screenImageMimeType {
                labeledValue("Type", mimeType)
              }
              if let width = entry.screenImageWidth, let height = entry.screenImageHeight {
                labeledValue("Dimensions", "\(width) × \(height)")
              }
            }
            .padding(8)
          }
        }

        Spacer()
      }
      .padding(16)
    }
  }

  // MARK: - Performance Tab
  private var performanceTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        GroupBox("Models") {
          VStack(alignment: .leading, spacing: 6) {
            if let transModel = entry.transcriptionModel {
              labeledValue("Transcription", transModel)
            }
            if let llmModel = entry.llmModel {
              labeledValue("LLM", llmModel)
            }
            if entry.transcriptionModel == nil && entry.llmModel == nil {
              Text("No model information available")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
          .padding(8)
        }

        GroupBox("Timing") {
          VStack(alignment: .leading, spacing: 6) {
            if let transTime = entry.transcriptionSeconds {
              labeledValue("Transcription", String(format: "%.2f s", transTime))
            }
            if let llmTime = entry.llmSeconds {
              labeledValue("LLM Processing", String(format: "%.2f s", llmTime))
            }
            if let totalTime = entry.totalSeconds {
              Divider()
              labeledValue("Total", String(format: "%.2f s", totalTime))
                .font(.headline)
            }
            if entry.transcriptionSeconds == nil &&
               entry.llmSeconds == nil &&
               entry.totalSeconds == nil {
              Text("No timing information available")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
          .padding(8)
        }

        GroupBox("Input") {
          VStack(alignment: .leading, spacing: 6) {
            labeledValue("Transcript Length", "\(entry.transcript.count) chars")
            labeledValue("Output Length", "\(entry.output.count) chars")
            let created = entry.date.formatted(date: .abbreviated, time: .standard)
            labeledValue("Timestamp", created)
          }
          .padding(8)
        }

        Spacer()
      }
      .padding(16)
    }
  }

  // MARK: - Raw JSON Tab
  private var jsonTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("Full History Entry (JSON)")
            .font(.headline)
          Spacer()
          Button { copyJSON() } label: {
            Label("Copy JSON", systemImage: "doc.on.doc")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        if let jsonString = entryAsJSON() {
          Text(jsonString)
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
        }

        Spacer()
      }
      .padding(16)
    }
  }

  // MARK: - Helpers
  private func debugSection(
    title: String,
    content: String,
    copyAction: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.subheadline)
          .fontWeight(.semibold)
        Spacer()
        Button { copyAction() } label: {
          Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }

      Text(content)
        .font(.system(.body, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .lineLimit(nil)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
    }
  }

  private func labeledValue(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(label)
        .foregroundColor(.secondary)
        .frame(width: 120, alignment: .leading)
      Text(value)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.callout)
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func entryAsJSON() -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(entry),
          let jsonString = String(data: data, encoding: .utf8) else {
      return nil
    }
    return jsonString
  }

  private func copyJSON() {
    if let jsonString = entryAsJSON() {
      copy(jsonString)
    }
  }
}
