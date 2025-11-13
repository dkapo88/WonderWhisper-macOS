import SwiftUI
import AppKit

struct SimpleHistoryView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var expandedEntries: Set<UUID> = []
  @State private var selectedEntryForDebug: HistoryEntry?

  private var entries: [HistoryEntry] { vm.history.entries }

  var body: some View {
    VStack(spacing: 0) {
      // History limit control at the top
      HStack(spacing: 12) {
        Text("Keep most recent")
          .font(.subheadline)
          .foregroundColor(.secondary)
        TextField("", value: Binding(
          get: { vm.history.maxEntries },
          set: { vm.history.maxEntries = $0 }
        ), formatter: NumberFormatter())
          .textFieldStyle(.roundedBorder)
          .frame(width: 60)
        Text(vm.history.maxEntries == 1 ? "entry" : "entries")
          .font(.subheadline)
          .foregroundColor(.secondary)
        
        Spacer()
        
        Text("Older entries are permanently deleted")
          .font(.caption)
          .foregroundColor(.secondary)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      .background(Color(nsColor: .controlBackgroundColor))
      .overlay(
        Divider(),
        alignment: .bottom
      )
      
      ScrollView {
        if entries.isEmpty {
          VStack(spacing: 12) {
            Image(systemName: "clock")
              .font(.system(size: 32))
              .foregroundColor(.secondary)
            Text("No history yet")
              .font(.headline)
            Text("Run a dictation or command request to see it appear here.")
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 240)
          .padding(.top, 40)
        } else {
          LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
            ForEach(entries, id: \.id) { entry in
              historyCard(for: entry)
            }
          }
          .padding(.vertical, 12)
        }
      }
      .padding(.horizontal, 20)
    }
    .sheet(item: $selectedEntryForDebug) { entry in
      PromptDebugView(entry: entry)
    }
  }

  private func historyCard(for entry: HistoryEntry) -> some View {
    let isExpanded = Binding(
      get: { expandedEntries.contains(entry.id) },
      set: { newValue in
        if newValue {
          expandedEntries.insert(entry.id)
        } else {
          expandedEntries.remove(entry.id)
        }
      }
    )

    return DisclosureGroup(isExpanded: isExpanded) {
      VStack(alignment: .leading, spacing: 10) {
        if !entry.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          GroupBox("AI Output") {
            VStack(alignment: .leading, spacing: 6) {
              Text(entry.output)
                .frame(maxWidth: .infinity, alignment: .leading)
              HStack {
                Spacer()
                Button { copy(entry.output) } label: {
                  Label("Copy AI Output", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
              }
            }
            .padding(8)
          }
        }

        GroupBox("Raw Transcript") {
          VStack(alignment: .leading, spacing: 6) {
            Text(entry.transcript.isEmpty ? "(empty)" : entry.transcript)
              .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
              Spacer()
              Button { copy(entry.transcript) } label: {
                Label("Copy Transcript", systemImage: "doc.on.doc")
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
            }
          }
          .padding(8)
        }

        // Debug prompt button
        if entry.llmSystemMessage != nil || entry.llmUserMessage != nil {
          HStack {
            Spacer()
            Button {
              selectedEntryForDebug = entry
            } label: {
              Label("View Prompt", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
      }
      .padding(.top, 6)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(entry.appName ?? "Unknown App")
            .font(.headline)
          Spacer()
          Text(entry.date.formatted(date: .abbreviated, time: .shortened))
            .font(.caption)
            .foregroundColor(.secondary)
        }
        Text(previewText(for: entry))
          .font(.subheadline)
          .foregroundColor(.primary)
          .lineLimit(2)
      }
      .padding(.vertical, 6)
    }
    .disclosureGroupStyle(PlainDisclosureGroupStyle())
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16)
        .fill(Color(nsColor: .windowBackgroundColor))
        .shadow(color: Color.black.opacity(0.06), radius: 6, y: 2)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(Color.secondary.opacity(0.12))
    )
  }

  private func previewText(for entry: HistoryEntry) -> String {
    let candidate = entry.output.isEmpty ? entry.transcript : entry.output
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "(empty)" }
    if trimmed.count <= 120 { return trimmed }
    let idx = trimmed.index(trimmed.startIndex, offsetBy: 120)
    return String(trimmed[..<idx]) + "…"
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

private struct PlainDisclosureGroupStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          configuration.isExpanded.toggle()
        }
      } label: {
        HStack {
          configuration.label
          Spacer()
          Image(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down")
            .foregroundColor(.secondary)
        }
      }
      .buttonStyle(.plain)

      if configuration.isExpanded {
        configuration.content
      }
    }
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
            .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
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
            .font(.caption)
            .foregroundColor(.secondary)
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
            .font(.caption)
            .foregroundColor(.secondary)
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
                  .font(.caption)
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
                .font(.caption)
                .foregroundColor(.secondary)
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
                .font(.caption)
                .foregroundColor(.secondary)
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
            .cornerRadius(6)
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
        .cornerRadius(6)
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
    .font(.caption)
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
