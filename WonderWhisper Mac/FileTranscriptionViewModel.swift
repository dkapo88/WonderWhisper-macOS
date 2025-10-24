import Foundation
import SwiftUI
import AVFoundation

// MARK: - Data Models

struct BenchmarkConfiguration: Identifiable, Codable {
    var id: UUID = UUID()
    var voiceModel: String
    var llmModel: String? // nil = "None"
    var llmProvider: String? // "groq", "openrouter", "cerebras", or nil
    var promptID: UUID? // nil = "None"
}

struct BenchmarkResult: Identifiable {
    var id: UUID = UUID()
    var configuration: BenchmarkConfiguration
    var audioDuration: TimeInterval
    var transcriptionTime: TimeInterval
    var llmProcessingTime: TimeInterval?
    var uploadTime: TimeInterval? // network latency if measurable
    var totalTime: TimeInterval
    var rawTranscript: String
    var processedOutput: String?
    var error: String?
}

// MARK: - ViewModel

@MainActor
class FileTranscriptionViewModel: ObservableObject {
    @Published var selectedFileURL: URL?
    @Published var selectedFileName: String?
    @Published var selectedFileSize: String?
    @Published var audioDuration: TimeInterval?
    @Published var configurations: [BenchmarkConfiguration] = []
    @Published var results: [BenchmarkResult] = []
    @Published var isRunning: Bool = false
    @Published var currentTestIndex: Int = 0
    @Published var totalTests: Int = 0
    @Published var expandedResults: Set<UUID> = []
    
    private let userDefaultsKey = "fileTranscription.lastConfig"
    
    init() {
        loadConfigurations()
        if configurations.isEmpty {
            addConfiguration() // Start with one default row
        }
    }
    
    // MARK: - File Selection
    
    func selectFile(url: URL) {
        selectedFileURL = url
        selectedFileName = url.lastPathComponent
        
        // Extract file size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int64 {
            selectedFileSize = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        }
        
        // Extract audio duration
        audioDuration = extractAudioDuration(from: url)
    }
    
    func clearFile() {
        selectedFileURL = nil
        selectedFileName = nil
        selectedFileSize = nil
        audioDuration = nil
        results = []
        expandedResults = []
    }
    
    func extractAudioDuration(from url: URL) -> TimeInterval? {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            return duration
        } catch {
            print("Failed to extract audio duration: \(error)")
            return nil
        }
    }
    
    // MARK: - Configuration Management
    
    func addConfiguration() {
        let newConfig = BenchmarkConfiguration(
            voiceModel: "whisper-large-v3-turbo",
            llmModel: nil,
            llmProvider: nil,
            promptID: nil
        )
        configurations.append(newConfig)
        persistConfigurations()
    }
    
    func removeConfiguration(id: UUID) {
        // Ensure at least one configuration remains
        guard configurations.count > 1 else { return }
        configurations.removeAll { $0.id == id }
        persistConfigurations()
    }
    
    // MARK: - Benchmark Execution
    
    func runBenchmark(dictationVM: DictationViewModel) async {
        guard let fileURL = selectedFileURL else { return }
        
        isRunning = true
        totalTests = configurations.count
        results = []
        expandedResults = []
        
        for (index, configuration) in configurations.enumerated() {
            currentTestIndex = index + 1
            
            do {
                let result = try await executeSingleBenchmark(
                    fileURL: fileURL,
                    configuration: configuration,
                    dictationVM: dictationVM
                )
                results.append(result)
                expandedResults.insert(result.id)
            } catch {
                // Create error result
                let errorResult = BenchmarkResult(
                    configuration: configuration,
                    audioDuration: audioDuration ?? 0,
                    transcriptionTime: 0,
                    llmProcessingTime: nil,
                    uploadTime: nil,
                    totalTime: 0,
                    rawTranscript: "",
                    processedOutput: nil,
                    error: error.localizedDescription
                )
                results.append(errorResult)
                expandedResults.insert(errorResult.id)
            }
        }
        
        isRunning = false
        
        // Save to history
        await saveToHistory(dictationVM: dictationVM)
    }
    
    private func executeSingleBenchmark(
        fileURL: URL,
        configuration: BenchmarkConfiguration,
        dictationVM: DictationViewModel
    ) async throws -> BenchmarkResult {
        let overallStart = Date()
        
        // Transcription Phase
        let transcriptionStart = Date()
        guard let transcriber = createTranscriptionProvider(for: configuration.voiceModel, dictationVM: dictationVM) else {
            throw NSError(domain: "FileTranscription", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create transcription provider for \(configuration.voiceModel)"])
        }
        
        let settings = TranscriptionSettings(
            endpoint: getEndpoint(for: configuration.voiceModel),
            model: configuration.voiceModel,
            timeout: 180,
            context: "file-benchmark"
        )
        
        let rawTranscript = try await transcriber.transcribe(fileURL: fileURL, settings: settings)
        let transcriptionTime = Date().timeIntervalSince(transcriptionStart)
        
        // LLM Processing Phase (if selected)
        var processedOutput: String?
        var llmProcessingTime: TimeInterval?
        
        if let llmModel = configuration.llmModel,
           let llmProvider = configuration.llmProvider {
            let llmStart = Date()
            
            guard let llm = createLLMProvider(provider: llmProvider, dictationVM: dictationVM) else {
                throw NSError(domain: "FileTranscription", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create LLM provider for \(llmProvider)"])
            }
            
            let (systemPrompt, userPrompt) = buildPrompt(for: configuration, dictationVM: dictationVM)
            
            let llmSettings = LLMSettings(
                endpoint: getLLMEndpoint(for: llmProvider),
                model: llmModel,
                systemPrompt: PromptBuilder.renderSystemPrompt(template: systemPrompt, customVocabulary: dictationVM.vocabCustom),
                timeout: 60,
                streaming: false,
                temperature: dictationVM.llmTemperature
            )
            
            processedOutput = try await llm.process(text: rawTranscript, userPrompt: userPrompt, settings: llmSettings)
            llmProcessingTime = Date().timeIntervalSince(llmStart)
        }
        
        let totalTime = Date().timeIntervalSince(overallStart)
        
        return BenchmarkResult(
            configuration: configuration,
            audioDuration: audioDuration ?? 0,
            transcriptionTime: transcriptionTime,
            llmProcessingTime: llmProcessingTime,
            uploadTime: nil, // TODO: Extract if provider exposes it
            totalTime: totalTime,
            rawTranscript: rawTranscript,
            processedOutput: processedOutput,
            error: nil
        )
    }
    
    // MARK: - Provider Creation
    
    private func createTranscriptionProvider(
        for model: String,
        dictationVM: DictationViewModel
    ) -> TranscriptionProvider? {
        let keychain = KeychainService()
        
        switch model {
        case "whisper-large-v3-turbo", "whisper-large-v3", "distil-whisper-large-v3-en":
            // Groq non-streaming
            if let apiKey = keychain.getSecret(forKey: AppConfig.groqAPIKeyAlias) {
                let client = GroqHTTPClient(apiKeyProvider: { apiKey })
                return GroqTranscriptionProvider(client: client)
            }
            
        case "whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe":
            // OpenAI
            if let apiKey = keychain.getSecret(forKey: AppConfig.openaiAPIKeyAlias) {
                let client = GroqHTTPClient(apiKeyProvider: { apiKey })
                return OpenAITranscriptionProvider(client: client)
            }
            
        case "parakeet-local":
            return ParakeetTranscriptionProvider()
            
        case "apple-native":
            return NativeAppleTranscriptionProvider()
            
        default:
            return nil
        }
        
        return nil
    }
    
    private func createLLMProvider(
        provider: String,
        dictationVM: DictationViewModel
    ) -> LLMProvider? {
        let keychain = KeychainService()
        
        switch provider.lowercased() {
        case "groq":
            if let apiKey = keychain.getSecret(forKey: AppConfig.groqAPIKeyAlias) {
                let client = GroqHTTPClient(apiKeyProvider: { apiKey })
                return GroqLLMProvider(client: client)
            }
            
        case "openrouter":
            if let apiKey = keychain.getSecret(forKey: AppConfig.openrouterAPIKeyAlias) {
                let client = OpenRouterHTTPClient(apiKeyProvider: { apiKey })
                return OpenRouterLLMProvider(client: client)
            }
            
        case "cerebras":
            if let apiKey = keychain.getSecret(forKey: AppConfig.cerebrasAPIKeyAlias) {
                let client = CerebrasHTTPClient(apiKeyProvider: { apiKey })
                return CerebrasLLMProvider(client: client)
            }
            
        default:
            return nil
        }
        
        return nil
    }
    
    private func buildPrompt(
        for configuration: BenchmarkConfiguration,
        dictationVM: DictationViewModel
    ) -> (systemPrompt: String, userPrompt: String) {
        if let promptID = configuration.promptID,
           let prompt = dictationVM.prompts.first(where: { $0.id == promptID }) {
            return (prompt.systemPrompt, prompt.userPrompt)
        } else {
            // Use default prompts from settings
            return (dictationVM.systemPrompt, dictationVM.userPrompt)
        }
    }
    
    private func getEndpoint(for model: String) -> URL {
        if model.lowercased().contains("openai") || model.lowercased().contains("whisper-1") || model.lowercased().contains("gpt-4o") {
            return AppConfig.openAIAudioTranscriptions
        }
        return AppConfig.groqAudioTranscriptions
    }
    
    private func getLLMEndpoint(for provider: String) -> URL {
        switch provider.lowercased() {
        case "openrouter":
            return AppConfig.openrouterChatCompletions
        case "cerebras":
            return AppConfig.cerebrasChatCompletions
        default:
            return AppConfig.groqChatCompletions
        }
    }
    
    // MARK: - History Integration
    
    func saveToHistory(dictationVM: DictationViewModel) async {
        guard let fileURL = selectedFileURL else { return }
        
        for result in results {
            // Skip if error occurred
            if result.error != nil { continue }
            
            // Save to history using HistoryStore.append which handles file copying
            await dictationVM.history.append(
                fileURL: fileURL,
                appName: "File Transcription Benchmark",
                bundleID: nil,
                transcript: result.rawTranscript,
                output: result.processedOutput ?? result.rawTranscript,
                screenContext: nil,
                screenContextMethod: nil,
                screenImage: nil,
                selectedText: nil,
                llmSystemMessage: nil,
                llmUserMessage: nil,
                transcriptionModel: result.configuration.voiceModel,
                llmModel: result.configuration.llmModel,
                transcriptionSeconds: result.transcriptionTime,
                llmSeconds: result.llmProcessingTime,
                totalSeconds: result.totalTime,
                copyFileOnly: true
            )
        }
    }
    
    // MARK: - Persistence
    
    func persistConfigurations() {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(configurations) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
    
    func loadConfigurations() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([BenchmarkConfiguration].self, from: data) {
            configurations = decoded
        }
    }
}
