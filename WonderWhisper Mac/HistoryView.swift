import SwiftUI

struct HistoryView: View {
    @ObservedObject var vm: DictationViewModel
    @EnvironmentObject var history: HistoryStore
    @State private var searchText: String = ""
    @State private var selectionID: HistoryEntry.ID?
    @State private var isReprocessing: Bool = false
    @State private var pendingDelete: HistoryEntry?

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(minWidth: 300, maxWidth: 360)
            Divider()
            detailPane
        }
        .onAppear { if selectionID == nil { selectionID = filtered.first?.id } }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            // Controls
            HStack {
                Text("Max entries").font(.caption)
                Spacer()
                Stepper("\(history.maxEntries)", value: $history.maxEntries, in: 10...500, step: 10)
                    .monospacedDigit()
            }
            .padding(.vertical, 6)

            if filtered.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "clock", description: Text("Start a dictation to see it here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectionID) {
                    ForEach(filtered) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.appName ?? "Unknown App").bold()
                                Spacer()
                                HStack(spacing: 6) {
                                    if let m = entry.screenContextMethod, !m.isEmpty {
                                        Text(m)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                }
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.output.isEmpty ? entry.transcript : entry.output)
                                .lineLimit(2)
                                .font(.subheadline)
                        }
                        .tag(entry.id)
                        .contextMenu {
                            Button("Copy Processed") { copy(entry.output.isEmpty ? entry.transcript : entry.output) }
                            Button("Copy Original") { copy(entry.transcript) }
                            Button {
                                triggerReprocess(for: entry)
                            } label: {
                                Label("Reprocess", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Button("Reveal in Finder") { history.revealInFinder(entry: entry) }
                            Divider()
                            Button(role: .destructive) { pendingDelete = entry } label: { Text("Delete") }
                        }
                    }
                    .onDelete(perform: deleteRows)
                }
                .searchable(text: $searchText)
                .listStyle(.inset)
            }
        }
        .padding([.leading, .trailing], 8)
        .confirmationDialog("Delete this history entry?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let e = pendingDelete { history.delete(entry: e); pendingDelete = nil; selectionID = history.entries.first?.id }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let e = pendingDelete { Text("This will delete the entry and any associated audio file.\n\n\(e.appName ?? "Unknown App") — \(e.date.formatted(date: .abbreviated, time: .shortened))") }
        }
    }

    private var detailPane: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let e = selectedEntry {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e.appName ?? "Unknown App").bold()
                                if let b = e.bundleID { Text(b).font(.caption).foregroundColor(.secondary) }
                            }
                            Spacer()
                            Button {
                                triggerReprocess(for: e)
                            } label: {
                                if isReprocessing {
                                    HStack(spacing: 6) {
                                        ProgressView().scaleEffect(0.8)
                                        Text("Reprocessing…")
                                    }
                                } else {
                                    Label("Reprocess", systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                            .disabled(isReprocessing)

                            Button(action: { history.revealInFinder(entry: e) }) { Label("Reveal", systemImage: "folder") }
                        }
                        HStack(spacing: 12) {
                            if let tm = e.transcriptionModel {
                                Label("Voice: \(tm)", systemImage: "mic").font(.caption)
                            }
                            if let lm = e.llmModel {
                                Label("LLM: \(lm)", systemImage: "brain.head.profile").font(.caption)
                            }
                            if let m = e.screenContextMethod, !m.isEmpty {
                                Label("Context: \(m)", systemImage: "eye").font(.caption)
                            }
                        }
                        HStack(spacing: 12) {
                            if let t = e.transcriptionSeconds {
                                Text(String(format: "ASR: %.2fs", t)).font(.caption).foregroundColor(.secondary)
                            }
                            if let l = e.llmSeconds {
                                Text(String(format: "LLM: %.2fs", l)).font(.caption).foregroundColor(.secondary)
                            }
                            if let tot = e.totalSeconds {
                                Text(String(format: "Total: %.2fs", tot)).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        GroupBox("Processed") {
                            VStack(alignment: .leading, spacing: 6) {
                                autoSizingTextBox(e.output, availableWidth: geo.size.width - 40)
                                HStack { Button("Copy Processed") { copy(e.output) } }
                            }
                            .padding(6)
                        }
                        GroupBox("Original Transcript") {
                            VStack(alignment: .leading, spacing: 6) {
                                autoSizingTextBox(e.transcript, availableWidth: geo.size.width - 40)
                                HStack { Button("Copy Original") { copy(e.transcript) } }
                            }
                            .padding(6)
                        }
                        // Replace Screen Context with full LLM prompt transparency
                        if let sys = e.llmSystemMessage, !sys.isEmpty {
                            GroupBox("System Message") {
                                VStack(alignment: .leading, spacing: 6) {
                                    autoSizingTextBox(sys, availableWidth: geo.size.width - 40)
                                    HStack { Button("Copy System Message") { copy(sys) } }
                                }.padding(6)
                            }
                        }
                        if let usr = e.llmUserMessage, !usr.isEmpty {
                            GroupBox("User Message") {
                                VStack(alignment: .leading, spacing: 6) {
                                    autoSizingTextBox(usr, availableWidth: geo.size.width - 40)
                                    HStack { Button("Copy User Message") { copy(usr) } }
                                }.padding(6)
                            }
                        }
                        if let sel = e.selectedText, !sel.isEmpty {
                            GroupBox("Selected Text") {
                                autoSizingTextBox(sel, availableWidth: geo.size.width - 40, maxHeight: 200, font: .caption)
                            }
                        }
                    } else {
                        ContentUnavailableView("Select an entry", systemImage: "doc.text")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: max(geo.size.width - 24, 300), alignment: .center)
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerReprocess(for entry: HistoryEntry) {
        guard !isReprocessing else { return }
        selectionID = entry.id
        isReprocessing = true
        Task {
            await vm.reprocessHistoryEntry(entry)
            await MainActor.run { isReprocessing = false }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var filtered: [HistoryEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter { e in
            (e.appName?.localizedCaseInsensitiveContains(q) ?? false) ||
            e.transcript.localizedCaseInsensitiveContains(q) ||
            e.output.localizedCaseInsensitiveContains(q)
        }
    }

    private var selectedEntry: HistoryEntry? {
        guard let id = selectionID else { return nil }
        return history.entries.first(where: { $0.id == id })
    }

    // MARK: - Helpers
    // Auto-sizing, scrollable text box that grows to fit content up to maxHeight and otherwise stays compact.
    @ViewBuilder
    private func autoSizingTextBox(_ text: String,
                                   availableWidth: CGFloat,
                                   minHeight: CGFloat = 16,
                                   maxHeight: CGFloat = 400,
                                   font: Font = .body) -> some View {
        let measured = estimateHeight(text: text, width: max(availableWidth - 16, 80), font: font)
        let height = min(max(measured, minHeight), maxHeight)
        ScrollView {
            Text(text)
                .font(font)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: height)
    }

    private func estimateHeight(text: String, width: CGFloat, font: Font) -> CGFloat {
        let uiFont: NSFont
        switch font {
        case .caption: uiFont = .systemFont(ofSize: NSFont.smallSystemFontSize)
        case .subheadline: uiFont = .systemFont(ofSize: 12)
        default: uiFont = .systemFont(ofSize: NSFont.systemFontSize)
        }
        let attr = [NSAttributedString.Key.font: uiFont]
        let bounding = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attr)
        return ceil(bounding.height) + 8
    }
}

// MARK: - Deletion helpers
private extension HistoryView {
    func deleteRows(at offsets: IndexSet) {
        // Map offsets in filtered array back to actual entries
        let toDelete = offsets.compactMap { idx in filtered.indices.contains(idx) ? filtered[idx] : nil }
        for e in toDelete { history.delete(entry: e) }
        selectionID = history.entries.first?.id
    }
}
