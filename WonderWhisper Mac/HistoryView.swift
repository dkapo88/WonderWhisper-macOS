import SwiftUI
import AppKit

struct HistoryView: View {
    @ObservedObject var vm: DictationViewModel
    @EnvironmentObject var history: HistoryStore
    @State private var selectionID: HistoryEntry.ID?
    @State private var isReprocessing: Bool = false
    @State private var pendingDelete: HistoryEntry?
    @State private var selectedImage: NSImage?
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var selectedImageURL: URL?

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(minWidth: 300, maxWidth: 360)
            Divider()
            detailPane
        }
        .onAppear { 
            if selectionID == nil && !history.entries.isEmpty { 
                selectionID = history.entries.first?.id 
            }
        }
    }
    
    private var listPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Max entries").font(.caption)
                Spacer()
                Stepper("\(history.maxEntries)", value: $history.maxEntries, in: 10...500, step: 10)
                    .monospacedDigit()
            }
            .padding(.vertical, 6)
            .padding([.leading, .trailing], 8)

            if history.entries.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading history...")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectionID) {
                    ForEach(history.entries, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.appName ?? "Unknown App").bold()
                                Spacer()
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.output.isEmpty ? entry.transcript : entry.output)
                                .lineLimit(2)
                                .font(.subheadline)
                        }
                        .tag(entry.id)
                    }
                    .onDelete(perform: deleteRows)
                    
                    if history.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding()
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding([.leading, .trailing], 8)
    }
    
    @ViewBuilder
    private var detailPane: some View {
        if let e = selectedEntry {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Color.clear.frame(height: 0)
                        .onAppear { selectedImage = nil; selectedImageURL = nil }
                        .onDisappear { imageLoadTask?.cancel() }
                    // Header with app name and reprocess button
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(e.appName ?? "Unknown App").bold()
                            if let b = e.bundleID { 
                                Text(b).font(.caption).foregroundColor(.secondary) 
                            }
                        }
                        Spacer()
                        if let audioURL = history.audioURL(for: e) {
                            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([audioURL]) }) {
                                Label("Reveal", systemImage: "folder")
                            }
                        }
                        Button(action: { reprocessEntry(e) }) {
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
                    }
                    
                    // Model info
                    HStack(spacing: 12) {
                        if let tm = e.transcriptionModel {
                            Label("Voice: \(tm)", systemImage: "mic").font(.caption)
                        }
                        if let lm = e.llmModel {
                            Label("LLM: \(lm)", systemImage: "brain.head.profile").font(.caption)
                        }
                    }
                    
                    // Timing info
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
                    
                    Divider()
                    
                    // Processed output
                    GroupBox("Processed Output") {
                        VStack(alignment: .leading, spacing: 6) {
                            ScrollView {
                                Text(e.output.isEmpty ? "(No output)" : e.output)
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 60)
                            HStack {
                                Button(action: { copyText(e.output) }) {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                                Spacer()
                            }
                        }
                        .padding(6)
                    }
                    
                    // Original transcript
                    GroupBox("Original Transcript") {
                        VStack(alignment: .leading, spacing: 6) {
                            ScrollView {
                                Text(e.transcript)
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 60)
                            HStack {
                                Button(action: { copyText(e.transcript) }) {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .font(.caption)
                                }
                                Spacer()
                            }
                        }
                        .padding(6)
                    }
                    
                    // System message
                    if let sys = e.llmSystemMessage, !sys.isEmpty {
                        GroupBox("System Message") {
                            VStack(alignment: .leading, spacing: 6) {
                                ScrollView {
                                    Text(sys)
                                        .font(.caption)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minHeight: 60)
                                HStack {
                                    Button(action: { copyText(sys) }) {
                                        Label("Copy", systemImage: "doc.on.doc")
                                            .font(.caption)
                                    }
                                    Spacer()
                                }
                            }
                            .padding(6)
                        }
                    }
                    
                    // User message
                    if let usr = e.llmUserMessage, !usr.isEmpty {
                        GroupBox("User Message") {
                            VStack(alignment: .leading, spacing: 6) {
                                ScrollView {
                                    Text(usr)
                                        .font(.caption)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minHeight: 60)
                                HStack {
                                    Button(action: { copyText(usr) }) {
                                        Label("Copy", systemImage: "doc.on.doc")
                                            .font(.caption)
                                    }
                                    Spacer()
                                }
                            }
                            .padding(6)
                        }
                    }
                    
                    // Screen context info
                    if let ctx = e.screenContext, !ctx.isEmpty {
                        GroupBox("Screen Context") {
                            VStack(alignment: .leading, spacing: 6) {
                                ScrollView {
                                    Text(ctx)
                                        .font(.caption)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minHeight: 60)
                                HStack {
                                    Button(action: { copyText(ctx) }) {
                                        Label("Copy", systemImage: "doc.on.doc")
                                            .font(.caption)
                                    }
                                    Spacer()
                                }
                            }
                            .padding(6)
                        }
                    }
                    
                    // Screen image
                    if let imageURL = history.imageURL(for: e) {
                        GroupBox("Screen Image") {
                            VStack(alignment: .leading, spacing: 6) {
                                if let nsImage = selectedImage, selectedImageURL == imageURL {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 220)
                                        .cornerRadius(6)
                                } else {
                                    ProgressView()
                                        .frame(height: 120)
                                }
                                HStack {
                                    Button(action: { NSWorkspace.shared.open(imageURL) }) {
                                        Label("Open", systemImage: "folder")
                                            .font(.caption)
                                    }
                                    Spacer()
                                }
                            }
                            .padding(6)
                        }
                        .onAppear {
                            loadImageAsync(from: imageURL)
                        }
                        .onDisappear {
                            imageLoadTask?.cancel()
                        }
                    }
                    
                    // Selected text
                    if let sel = e.selectedText, !sel.isEmpty {
                        GroupBox("Selected Text") {
                            VStack(alignment: .leading, spacing: 6) {
                                ScrollView {
                                    Text(sel)
                                        .font(.caption)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minHeight: 60)
                                HStack {
                                    Button(action: { copyText(sel) }) {
                                        Label("Copy", systemImage: "doc.on.doc")
                                            .font(.caption)
                                    }
                                    Spacer()
                                }
                            }
                            .padding(6)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                Text("Select an entry")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    private var selectedEntry: HistoryEntry? {
        guard let id = selectionID else { return nil }
        return history.entries.first(where: { $0.id == id })
    }
    
    private func deleteRows(at offsets: IndexSet) {
        for idx in offsets {
            if idx < history.entries.count {
                history.delete(entry: history.entries[idx])
            }
        }
        selectionID = history.entries.first?.id
    }
    
    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func reprocessEntry(_ entry: HistoryEntry) {
        guard !isReprocessing else { return }
        isReprocessing = true
        Task {
            await vm.reprocessHistoryEntry(entry)
            await MainActor.run { isReprocessing = false }
        }
    }
    
    private func loadImageAsync(from url: URL) {
        imageLoadTask?.cancel()
        selectedImageURL = url
        selectedImage = nil
        
        imageLoadTask = Task {
            let image = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            
            await MainActor.run {
                if selectedImageURL == url {
                    selectedImage = image
                }
            }
        }
    }
}
