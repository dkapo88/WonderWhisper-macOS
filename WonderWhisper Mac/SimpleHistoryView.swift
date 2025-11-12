import SwiftUI
import AppKit

struct SimpleHistoryView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var expandedEntries: Set<UUID> = []
  @State private var selectedEntryForDebug: HistoryEntry?
  @State private var showDebugModal = false

  private var entries: [HistoryEntry] { vm.history.entries }

  var body: some View {
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
    .sheet(isPresented: $showDebugModal) {
      if let entry = selectedEntryForDebug {
        PromptDebugView(entry: entry)
      }
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
              showDebugModal = true
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
