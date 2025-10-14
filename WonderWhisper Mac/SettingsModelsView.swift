import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(FluidAudio)
import FluidAudio
#endif

struct SettingsModelsView: View {
    @ObservedObject var vm: DictationViewModel
    @AppStorage("parakeet.version") private var parakeetVersion: String = "v3"
    @State private var favoriteModelDraft: String = ""
    @State private var favoriteProviderDraft: String

    init(vm: DictationViewModel) {
        _vm = ObservedObject(wrappedValue: vm)
        _favoriteModelDraft = State(initialValue: "")
        _favoriteProviderDraft = State(initialValue: vm.llmProvider.lowercased())
    }

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Voice model", selection: $vm.transcriptionModel) {
                    Text("whisper-large-v3-turbo").tag("whisper-large-v3-turbo")
                    Text("whisper-large-v3").tag("whisper-large-v3")
                    Text("distil-whisper-large-v3-en").tag("distil-whisper-large-v3-en")
                    if #available(macOS 26, *) {
                        Text("Apple Native (macOS 26+)").tag("apple-native")
                    }
                    Text("Groq (Chunked Streaming)").tag("groq-streaming")
                    Text("Parakeet (local)").tag("parakeet-local")
                    Text("AssemblyAI (Streaming)").tag("assemblyai-streaming")
                    Text("Deepgram (Streaming)").tag("deepgram-streaming")
                    Text("Soniox (Streaming)").tag("soniox-streaming")
                }

                // Groq Whisper options (language + prompt), shown for Groq Whisper models and streaming
                if ["whisper-large-v3-turbo", "whisper-large-v3", "distil-whisper-large-v3-en", "groq-streaming"].contains(vm.transcriptionModel) {
                    GroupBox("Groq Whisper options") {
                        VStack(alignment: .leading, spacing: 10) {
                            // Language picker (common codes)
                            HStack {
                                Text("Language")
                                Spacer()
                                Picker("Language", selection: $vm.transcriptionLanguage) {
                                    Text("English (en)").tag("en")
                                    Text("Spanish (es)").tag("es")
                                    Text("French (fr)").tag("fr")
                                    Text("German (de)").tag("de")
                                    Text("Italian (it)").tag("it")
                                    Text("Portuguese (pt)").tag("pt")
                                    Text("Chinese (zh)").tag("zh")
                                    Text("Japanese (ja)").tag("ja")
                                    Text("Korean (ko)").tag("ko")
                                    Text("Hindi (hi)").tag("hi")
                                    Text("Arabic (ar)").tag("ar")
                                    Text("Russian (ru)").tag("ru")
                                    Text("Dutch (nl)").tag("nl")
                                    Text("Swedish (sv)").tag("sv")
                                    Text("Turkish (tr)").tag("tr")
                                    Text("Vietnamese (vi)").tag("vi")
                                    Text("Polish (pl)").tag("pl")
                                    Divider()
                                    Text("Custom (\(vm.transcriptionLanguage))").tag(vm.transcriptionLanguage)
                                }
                                .labelsHidden()
                                .frame(maxWidth: 220)
                                .help("BCP-47 language code sent to Groq (default: English)")
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                if vm.transcriptionModel == "groq-streaming" {
                    GroupBox("Groq Chunked Streaming") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(.yellow)
                                Text("Faster results through intelligent audio chunking")
                                    .font(.subheadline)
                            }
                            Text("• Processes audio in 3-second chunks for faster response times")
                            Text("• Results appear within seconds instead of waiting for full recording")
                            Text("• Ideal for longer recordings and real-time feedback")
                            Text("• Uses whisper-large-v3-turbo for optimal speed/accuracy balance")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    }
                } else if vm.transcriptionModel == "soniox-streaming" {
                    GroupBox("Soniox Streaming") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Enable endpoint detection", isOn: $vm.sonioxEndpointDetection)
                                .help("Server-side end-of-speech detection. Recommended OFF; finalize on end-of-stream for accuracy.")
                            Toggle("Enable language identification", isOn: $vm.sonioxLanguageIdentification)
                            Toggle("Enable speaker diarization", isOn: $vm.sonioxSpeakerDiarization)

                            // Accuracy Presets
                            GroupBox("Accuracy Presets") {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Quick setup for common use cases:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    HStack {
                                        Button("Medical") {
                                            vm.applySonioxPreset(.medical)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button("Legal") {
                                            vm.applySonioxPreset(.legal)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button("Technical") {
                                            vm.applySonioxPreset(.technical)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)

                                        Button("General") {
                                            vm.applySonioxPreset(.general)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }

                                    Text("Presets configure context and vocabulary for maximum accuracy in specific domains.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider().padding(.vertical, 2)

                            // Context Configuration for Maximum Accuracy
                            GroupBox("Context & Vocabulary (Critical for Accuracy)") {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Keywords & Names")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField(
                                        "Enter keywords, names, technical terms (comma-separated)",
                                        text: $vm.sonioxContextKeywords,
                                        axis: .vertical
                                    )
                                    .lineLimit(2...4)
                                    .textFieldStyle(.roundedBorder)
                                    Text("Example: Celebrex, Zyrtec, Xanax, API endpoint, PostgreSQL")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)

                                    Divider().padding(.vertical, 2)

                                    Text("Domain Context")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField(
                                        "Describe your domain or topic for better accuracy",
                                        text: $vm.sonioxContextParagraph,
                                        axis: .vertical
                                    )
                                    .lineLimit(2...6)
                                    .textFieldStyle(.roundedBorder)
                                    Text("Example: Medical consultation discussing patient medications and treatment options.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            // Language Hints Configuration
                            GroupBox("Language Hints") {
                                VStack(alignment: .leading, spacing: 6) {
                                    TextField(
                                        "Expected languages (comma-separated, e.g., en, es, fr)",
                                        text: $vm.sonioxLanguageHints
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    Text("Helps the model recognize specific languages more accurately.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Divider().padding(.vertical, 2)

                            // Audio Processing Options
                            GroupBox("Audio Processing") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Toggle("Enable mic EQ (HPF + hum notch)", isOn: $vm.audioStreamEQEnabled)
                                    Toggle("Enable dynamics (compress/expand)", isOn: $vm.audioStreamDynamicsEnabled)
                                    HStack {
                                        Stepper("Chunk size: \(vm.audioStreamChunkMs) ms", value: $vm.audioStreamChunkMs, in: 5...60, step: 5)
                                        Spacer()
                                    }
                                    Text("Use 10–20 ms for smoother, low-latency streaming.")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                } else if vm.transcriptionModel.lowercased().contains("parakeet") || vm.transcriptionModel.lowercased().contains("local") {
                    GroupBox("Parakeet Status") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 12) {
                                Label(ParakeetManager.isLinked ? "Framework: Linked" : "Framework: Not Linked", systemImage: ParakeetManager.isLinked ? "checkmark.seal" : "xmark.seal")
                                    .foregroundColor(ParakeetManager.isLinked ? .green : .red)
                                Label(ParakeetManager.modelsPresent() ? "Models: Present" : "Models: Missing", systemImage: ParakeetManager.modelsPresent() ? "checkmark.seal" : "xmark.seal")
                                    .foregroundColor(ParakeetManager.modelsPresent() ? .green : .red)
                            }
                            HStack(spacing: 12) {
                                Button("Download/Update Both Models") { Task { await downloadParakeet() } }
                                    .disabled(!ParakeetManager.isLinked)
                                Button("Show in Finder") { NSWorkspace.shared.selectFile(ParakeetManager.effectiveModelsDirectory.path, inFileViewerRootedAtPath: "") }
                                Button("Remove Models") { ParakeetManager.removeAllModels() }
                                    .disabled(!ParakeetManager.modelsPresent())
                            }
                            Text("Selected engine: \(parakeetVersion.uppercased())  •  Path: \(ParakeetManager.effectiveModelsDirectory.path)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    GroupBox("Parakeet Advanced") {
                        ParakeetAdvancedSettingsView()
                    }
                }
            }
            Section("LLM") {
                Toggle("Post-processing with LLM", isOn: $vm.llmEnabled)
                Toggle("Include screen context (selection/OCR)", isOn: $vm.screenContextEnabled)
                    .help("When off, no selection/AX/OCR or app context is collected or used by the LLM. Tags remain empty.")
                Toggle("Include clipboard context (last 10 seconds)", isOn: $vm.clipboardContextEnabled)
                    .help("Send clipboard text copied within 10 seconds before recording inside <CLIPBOARD> tags.")

                Picker("Screen content preprocessing", selection: $vm.screenContextPreprocessingMode) {
                    ForEach(ScreenContextPreprocessingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Choose how to preprocess OCR screen captures before the main LLM prompt: off, on-device keyword extraction, or an LLM organization pass.")
                Text("On-device mode extracts key terms locally; LLM mode sends a quick organizing prompt before the main request.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Organization prompt")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $vm.screenOrganizePrompt)
                        .font(.body)
                        .frame(minHeight: 60, maxHeight: 120)
                        .disabled(vm.screenContextPreprocessingMode != .llm)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2))
                        )
                        .help("Customize the instruction sent to the quick LLM pass that organizes OCR'd screen content before your main prompt.")
                }
                .padding(.top, 4)


                Picker("LLM Provider", selection: $vm.llmProvider) {
                    Text("Groq").tag("groq")
                    Text("OpenRouter").tag("openrouter")
                    Text("Cerebras").tag("cerebras")
                }
                if vm.llmProvider == "openrouter" {

                    // Routing preference
                    Picker("Routing Preference", selection: $vm.openrouterRouting) {
                        Text("Prioritize latency").tag("latency")
                        Text("Prioritize throughput").tag("throughput")
                    }
                    // Searchable model selector for OpenRouter
                    OpenRouterModelSelector(selectedModel: $vm.llmModel)
                } else if vm.llmProvider == "cerebras" {
                    // Cerebras models (Production + Preview)
                    Picker("LLM model", selection: $vm.llmModel) {
                        // Production
                        Text("llama-4-scout-17b-16e-instruct").tag("llama-4-scout-17b-16e-instruct")
                        Text("llama3.1-8b").tag("llama3.1-8b")
                        Text("llama-3.3-70b").tag("llama-3.3-70b")
                        Text("gpt-oss-120b").tag("gpt-oss-120b")
                        Text("qwen-3-32b").tag("qwen-3-32b")
                        Divider()
                        // Preview (not for production)
                        Text("[Preview] llama-4-maverick-17b-128e-instruct").tag("llama-4-maverick-17b-128e-instruct")
                        Text("[Preview] qwen-3-235b-a22b-instruct-2507").tag("qwen-3-235b-a22b-instruct-2507")
                        Text("[Preview] qwen-3-235b-a22b-thinking-2507").tag("qwen-3-235b-a22b-thinking-2507")
                        Text("[Preview] qwen-3-coder-480b").tag("qwen-3-coder-480b")
                    }
                } else {
                    // Existing static picker for Groq-backed models
                    Picker("LLM model", selection: $vm.llmModel) {
                        Text("moonshotai/kimi-k2-instruct").tag("moonshotai/kimi-k2-instruct")
                        Text("moonshotai/kimi-k2-instruct-0905").tag("moonshotai/kimi-k2-instruct-0905")
                        Text("openai/gpt-oss-120b").tag("openai/gpt-oss-120b")
                        Text("meta-llama/llama-4-scout-17b-16e-instruct").tag("meta-llama/llama-4-scout-17b-16e-instruct")
                    }
                }
                Toggle("Streaming (SSE)", isOn: $vm.llmStreaming)
                    .help("Enable streaming responses for faster time-to-first-token. Uses the same prompt and output format.")

                GroupBox("Favorite LLM models") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Provider", selection: $favoriteProviderDraft) {
                            ForEach(providerOptions, id: \.self) { provider in
                                Text(providerDisplayName(provider)).tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)

                        HStack(spacing: 8) {
                            TextField("Add model identifier", text: $favoriteModelDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                                .onSubmit { addFavoriteDraft() }
                            Button("Add") { addFavoriteDraft() }
                                .disabled(favoriteModelDraftTrimmed.isEmpty)
                        }

                        Button("Add current model (\(vm.llmModel))") {
                            vm.addFavoriteLLMModel(provider: vm.llmProvider.lowercased(), model: vm.llmModel)
                        }
                        .buttonStyle(.borderless)
                        .disabled(vm.llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFavorite(provider: vm.llmProvider, model: vm.llmModel))

                        if vm.favoriteLLMModels.isEmpty {
                            Text("No favorites yet. Add the identifiers of the models you use most often. These appear in the prompt library quick picker.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(groupedFavorites, id: \.provider) { provider, models in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(providerDisplayName(provider))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        ForEach(models) { favorite in
                                            HStack {
                                                Text(favorite.model)
                                                    .font(.system(.body, design: .monospaced))
                                                Spacer()
                                                Button("Remove") { vm.removeFavoriteLLMModel(id: favorite.id) }
                                                    .buttonStyle(.borderless)
                                            }
                                            .padding(.vertical, 2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: vm.llmProvider) { newValue in
            if providerOptions.contains(where: { $0.caseInsensitiveCompare(newValue) == .orderedSame }) {
                favoriteProviderDraft = newValue.lowercased()
            }
        }
    }

    private var favoriteModelDraftTrimmed: String {
        favoriteModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addFavoriteDraft() {
        let trimmed = favoriteModelDraftTrimmed
        guard !trimmed.isEmpty else { return }
        vm.addFavoriteLLMModel(provider: favoriteProviderDraft.lowercased(), model: trimmed)
        favoriteModelDraft = ""
    }

    private func isFavorite(provider: String, model: String) -> Bool {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return false }
        let normalizedProvider = (trimmedProvider.isEmpty ? vm.llmProvider : trimmedProvider).lowercased()
        let candidate = FavoriteLLMModel(provider: normalizedProvider, model: trimmedModel)
        return vm.favoriteLLMModels.contains { $0.key == candidate.key }
    }

    private func providerDisplayName(_ provider: String) -> String {
        switch provider.lowercased() {
        case "openrouter":
            return "OpenRouter"
        case "cerebras":
            return "Cerebras"
        default:
            return "Groq"
        }
    }

    private var providerOptions: [String] {
        var options: [String] = ["groq", "openrouter", "cerebras"]
        for favorite in vm.favoriteLLMModels {
            let provider = favorite.provider.lowercased()
            if !options.contains(where: { $0.caseInsensitiveCompare(provider) == .orderedSame }) {
                options.append(provider)
            }
        }
        return options
    }

    private var groupedFavorites: [(provider: String, models: [FavoriteLLMModel])] {
        var order: [String] = []
        var groups: [String: [FavoriteLLMModel]] = [:]
        for favorite in vm.favoriteLLMModels {
            let key = favorite.provider.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(favorite)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    @MainActor
    private func downloadParakeet() async {
        #if canImport(FluidAudio)
        do {
            _ = try await AsrModels.downloadAndLoad(version: .v2)
            _ = try await AsrModels.downloadAndLoad(version: .v3)
        } catch {
            // ignore; UI shows present/missing
        }
        #endif
    }
}

// MARK: - OpenRouter model selector view
fileprivate struct OpenRouterModelSelector: View {
    @Binding var selectedModel: String
    @State private var query: String = ""
    @State private var models: [String] = []
    @State private var isLoading: Bool = false
    @State private var lastLoad: Date? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search OpenRouter models", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                Button(isLoading ? "Refreshing…" : "Refresh") { Task { await loadModels(force: true) } }
                    .disabled(isLoading)
            }
            if let err = errorMessage {
                Text(err).font(.caption).foregroundColor(.red)
            }
            let filtered = filteredModels()
            if filtered.isEmpty {
                Text(isLoading ? "Loading…" : "No models found").font(.caption).foregroundColor(.secondary)
            } else {
                List(filtered, id: \.self) { id in
                    HStack {

                        Text(id)
                        Spacer()
                        if id == selectedModel { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedModel = id }
                }
                .frame(maxHeight: 220)
            }
            HStack(spacing: 6) {
                Text("Tip: choose 'openrouter/auto' to let OpenRouter route by \(UserDefaults.standard.string(forKey: "llm.openrouter.routing") ?? "latency").")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { Task { await loadModels(force: false) } }
        .onChange(of: query) { _, _ in /* local filter only */ }
    }

    private func filteredModels() -> [String] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return models
        }
        let q = query.lowercased()
        return models.filter { $0.lowercased().contains(q) }
    }

    @MainActor
    private func loadModels(force: Bool) async {
        guard !isLoading else { return }
        if !force, let last = lastLoad, Date().timeIntervalSince(last) < 15 * 60, !models.isEmpty { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // Use API key from keychain if available (optional for /models)
            let key = KeychainService().getSecret(forKey: AppConfig.openrouterAPIKeyAlias) ?? ""
            let client = OpenRouterHTTPClient(apiKeyProvider: { key })
            let ids = try await client.fetchModelIDs()
            // Include router model explicitly
            let withAuto = (["openrouter/auto"] + ids).uniqued()
            self.models = withAuto
            self.lastLoad = Date()
            self.errorMessage = nil
        } catch {
            self.errorMessage = "Failed to load models. Check your network and try again."
        }
    }
}

fileprivate extension Array where Element: Hashable {
    func uniqued() -> [Element] { Array(Set(self)).sorted { String(describing: $0) < String(describing: $1) } }
}
