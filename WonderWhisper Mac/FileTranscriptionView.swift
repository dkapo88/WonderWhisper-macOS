import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
    @ObservedObject var dictationVM: DictationViewModel
    @StateObject private var vm = FileTranscriptionViewModel()
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                fileSelectionSection
                configurationTableSection
                if !vm.results.isEmpty {
                    resultsSection
                }
            }
            .padding()
        }
        .navigationTitle("File Transcription")
    }
    
    // MARK: - File Selection Section
    
    private var fileSelectionSection: some View {
        GroupBox(label: Text("Audio File").font(.headline)) {
            VStack(spacing: 12) {
                if vm.selectedFileURL != nil {
                    // Display selected file info
                    HStack {
                        Image(systemName: "waveform")
                            .font(.largeTitle)
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(vm.selectedFileName ?? "Unknown")
                                .font(.headline)
                            HStack(spacing: 12) {
                                if let size = vm.selectedFileSize {
                                    Text("Size: \(size)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if let duration = vm.audioDuration {
                                    Text("Duration: \(String(format: "%.1f", duration))s")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Button("Clear") {
                            vm.clearFile()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                } else {
                    // Drop zone + file picker
                    VStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(style: StrokeStyle(lineWidth: 2, dash: [8]))
                                .foregroundColor(.accentColor.opacity(0.5))
                                .frame(height: 120)
                            
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary)
                                Text("Drag and drop audio file here")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            handleDrop(providers: providers)
                            return true
                        }
                        
                        Button(action: { showFilePicker() }) {
                            Label("Choose File", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                }
            }
        }
    }
    
    // MARK: - Configuration Table Section
    
    private var configurationTableSection: some View {
        VStack(spacing: 12) {
            GroupBox(label: Text("Test Configurations").font(.headline)) {
                VStack(spacing: 0) {
                    // Header Row
                    HStack(spacing: 12) {
                        Text("Voice Model")
                            .frame(minWidth: 200, alignment: .leading)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("LLM Model")
                            .frame(minWidth: 200, alignment: .leading)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Prompt")
                            .frame(minWidth: 150, alignment: .leading)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("")
                            .frame(width: 40)
                    }
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.1))
                    
                    Divider()
                    
                    // Configuration Rows
                    ForEach(vm.configurations) { config in
                        configurationRow(config: config)
                        Divider()
                    }
                    
                    // Add Configuration Button
                    Button(action: { vm.addConfiguration() }) {
                        Label("Add Configuration", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }
            }
            
            // Run Benchmark Button
            HStack {
                Button(action: {
                    Task {
                        await vm.runBenchmark(dictationVM: dictationVM)
                    }
                }) {
                    if vm.isRunning {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Testing \(vm.currentTestIndex) of \(vm.totalTests)...")
                        }
                    } else {
                        Label("Run Benchmark", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedFileURL == nil || vm.isRunning || vm.configurations.isEmpty)
                
                Spacer()
            }
        }
    }
    
    private func configurationRow(config: BenchmarkConfiguration) -> some View {
        HStack(spacing: 12) {
            // Voice Model Picker
            Picker("", selection: binding(for: config.id, keyPath: \.voiceModel)) {
                ForEach(availableVoiceModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .frame(minWidth: 200)
            
            // LLM Model Picker
            Picker("", selection: binding(for: config.id, keyPath: \.llmModel)) {
                Text("None").tag(nil as String?)
                ForEach(dictationVM.favoriteLLMModels) { llm in
                    Text("\(llm.provider): \(llm.model)").tag(llm.model as String?)
                }
            }
            .frame(minWidth: 200)
            .onChange(of: binding(for: config.id, keyPath: \.llmModel).wrappedValue) { _, newValue in
                // Auto-set provider when model is selected
                if let llmModel = newValue,
                   let favorite = dictationVM.favoriteLLMModels.first(where: { $0.model == llmModel }) {
                    if let index = vm.configurations.firstIndex(where: { $0.id == config.id }) {
                        vm.configurations[index].llmProvider = favorite.provider.lowercased()
                        vm.persistConfigurations()
                    }
                }
            }
            
            // Prompt Picker
            Picker("", selection: binding(for: config.id, keyPath: \.promptID)) {
                Text("None").tag(nil as UUID?)
                ForEach(dictationVM.prompts) { prompt in
                    Text(prompt.name).tag(prompt.id as UUID?)
                }
            }
            .frame(minWidth: 150)
            
            // Delete Button
            Button(action: { vm.removeConfiguration(id: config.id) }) {
                Image(systemName: "trash")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .frame(width: 40)
            .disabled(vm.configurations.count <= 1) // Minimum 1 row
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
    
    private var availableVoiceModels: [String] {
        [
            "whisper-large-v3-turbo",
            "whisper-large-v3",
            "distil-whisper-large-v3-en",
            "whisper-1",
            "gpt-4o-mini-transcribe",
            "gpt-4o-transcribe",
            "parakeet-local",
            "apple-native"
        ]
    }
    
    // MARK: - Results Section
    
    private var resultsSection: some View {
        GroupBox(label: Text("Benchmark Results").font(.headline)) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ],
                spacing: 16
            ) {
                ForEach(vm.results) { result in
                    resultCard(result: result)
                }
            }
            .padding(.top, 8)
        }
    }
    
    private func resultCard(result: BenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            DisclosureGroup(
                isExpanded: expandedBinding(for: result.id),
                content: {
                    VStack(alignment: .leading, spacing: 16) {
                        // Performance Metrics
                        metricsGrid(result: result)
                        
                        // Raw Transcript
                        GroupBox(label: Text("Raw Transcript").font(.subheadline)) {
                            ScrollView {
                                Text(result.rawTranscript)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 150)
                        }
                        
                        // Processed Output
                        if let processed = result.processedOutput {
                            GroupBox(label: Text("Processed Output").font(.subheadline)) {
                                ScrollView {
                                    Text(processed)
                                        .font(.body)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(height: 150)
                            }
                        }
                        
                        // Error if any
                        if let error = result.error {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .padding(8)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(6)
                        }
                    }
                    .padding(.top, 8)
                },
                label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Voice: \(result.configuration.voiceModel)")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            HStack(spacing: 8) {
                                if let llm = result.configuration.llmModel {
                                    Text("LLM: \(llm)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                if let promptID = result.configuration.promptID,
                                   let prompt = dictationVM.prompts.first(where: { $0.id == promptID }) {
                                    Text("Prompt: \(prompt.name)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Text(String(format: "%.1fs", result.totalTime))
                            .font(.headline)
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(8)
                    }
                }
            )
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }
    
    private func metricsGrid(result: BenchmarkResult) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            metricItem(label: "Audio Duration", value: String(format: "%.1fs", result.audioDuration))
            metricItem(label: "Transcription Time", value: String(format: "%.1fs", result.transcriptionTime))
            if let llmTime = result.llmProcessingTime {
                metricItem(label: "LLM Processing", value: String(format: "%.1fs", llmTime))
            } else {
                metricItem(label: "LLM Processing", value: "N/A")
            }
            metricItem(label: "Total Time", value: String(format: "%.1fs", result.totalTime))
            if let uploadTime = result.uploadTime {
                metricItem(label: "Upload/Network", value: String(format: "%.1fs", uploadTime))
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func metricItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Helper Methods
    
    private func binding<T>(for id: UUID, keyPath: WritableKeyPath<BenchmarkConfiguration, T>) -> Binding<T> where T: Equatable {
        Binding(
            get: {
                vm.configurations.first(where: { $0.id == id })?[keyPath: keyPath] ?? getDefaultValue(for: keyPath)
            },
            set: { newValue in
                if let index = vm.configurations.firstIndex(where: { $0.id == id }) {
                    vm.configurations[index][keyPath: keyPath] = newValue
                    vm.persistConfigurations()
                }
            }
        )
    }
    
    private func getDefaultValue<T>(for keyPath: WritableKeyPath<BenchmarkConfiguration, T>) -> T {
        if keyPath == \BenchmarkConfiguration.voiceModel {
            return "whisper-large-v3-turbo" as! T
        } else if keyPath == \BenchmarkConfiguration.llmModel {
            return Optional<String>.none as! T
        } else if keyPath == \BenchmarkConfiguration.llmProvider {
            return Optional<String>.none as! T
        } else if keyPath == \BenchmarkConfiguration.promptID {
            return Optional<UUID>.none as! T
        }
        fatalError("Unsupported keyPath")
    }
    
    private func expandedBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { vm.expandedResults.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    vm.expandedResults.insert(id)
                } else {
                    vm.expandedResults.remove(id)
                }
            }
        )
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (urlData, error) in
            DispatchQueue.main.async {
                if let urlData = urlData as? Data,
                   let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                    vm.selectFile(url: url)
                }
            }
        }
    }
    
    private func showFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .audio,
            .wav,
            .mp3,
            .mpeg4Audio,
            .init(filenameExtension: "m4a") ?? .audio,
            .init(filenameExtension: "aac") ?? .audio,
            .init(filenameExtension: "ogg") ?? .audio,
            .init(filenameExtension: "flac") ?? .audio
        ]
        panel.message = "Choose an audio file to transcribe"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                vm.selectFile(url: url)
            }
        }
    }
}
