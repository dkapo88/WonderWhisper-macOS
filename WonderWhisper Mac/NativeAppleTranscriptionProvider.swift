import Foundation
import AVFoundation
import OSLog

#if canImport(Speech)
import Speech
#endif

/// Provides transcription using Apple's native SpeechAnalyzer/SpeechTranscriber APIs available on macOS 26.
/// Falls back gracefully on older systems or when the build flag is disabled.
final class NativeAppleTranscriptionProvider: TranscriptionProvider {
    private let logger = Logger(subsystem: "com.slumdev88.wonderwhisper.WonderWhisper-Mac", category: "NativeAppleTranscription")
    
    enum ServiceError: Error, LocalizedError {
        case unsupportedOS
        case unsupportedBuild
        case invalidLocale
        
        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                return "Apple native transcription requires macOS 26 or later."
            case .unsupportedBuild:
                return "Apple native transcription support is not enabled in this build."
            case .invalidLocale:
                return "The selected language is not currently supported."
            }
        }
    }
    
    func transcribe(fileURL: URL, settings: TranscriptionSettings) async throws -> String {
        guard #available(macOS 26, *) else {
            throw ServiceError.unsupportedOS
        }
        
        #if canImport(Speech) && ENABLE_NATIVE_SPEECH_ANALYZER
        let audioFile = try AVAudioFile(forReading: fileURL)
        let locale = try await resolveLocale()
        
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        await ensureModelAvailabilityHints(for: transcriber, locale: locale)
        
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        logger.notice("Starting native Apple transcription locale=\(locale.identifier(.bcp47)) file=\(fileURL.lastPathComponent)")
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        
        var transcript: AttributedString = ""
        for try await result in transcriber.results {
            transcript += result.text
        }
        
        var output = String(transcript.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if UserDefaults.standard.object(forKey: "transcription.postprocess.enabled") as? Bool ?? true {
            // Post-processing can be added here if needed, but no redundant trimming
        }
        logger.notice("Native Apple transcription finished chars=\(output.count)")
        return output
        #else
        throw ServiceError.unsupportedBuild
        #endif
    }
    
    // MARK: - Locale Handling
    @available(macOS 26, *)
    private func resolveLocale() async throws -> Locale {
        let preferred = UserDefaults.standard.string(forKey: "transcription.language") ?? Locale.preferredLanguages.first ?? "en"
        let localeIdentifier = mapToAppleLocale(preferred)
        let locale = Locale(identifier: localeIdentifier)
        
        let supported = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        if !supported.contains(locale.identifier(.bcp47)) {
            logger.error("Locale not supported by SpeechTranscriber locale=\(locale.identifier(.bcp47))")
            throw ServiceError.invalidLocale
        }
        return locale
    }
    
    private func mapToAppleLocale(_ code: String) -> String {
       let lower = code.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
       let mapping: [String: String] = [
           "en": "en-US",
           "es": "es-ES",
           "fr": "fr-FR",
           "de": "de-DE",
           "ar": "ar-SA",
           "it": "it-IT",
           "ja": "ja-JP",
           "ko": "ko-KR",
           "pt": "pt-BR",
           "yue": "yue-CN",
           "zh": "zh-CN"
       ]
       
       // If the code already contains a dash and appears to be a valid locale format, use it as is
       if lower.contains("-") {
           let components = lower.split(separator: "-")
           if components.count >= 2 && !components[0].isEmpty && !components[1].isEmpty {
               return code
           }
       }
       
       // Try to map the language code to a full locale identifier
       if let mappedLocale = mapping[lower] {
           return mappedLocale
       }
       
       // Fallback to en-US for unmapped languages
       return "en-US"
   }
    
    // MARK: - Asset availability logging
    @available(macOS 26, *)
    private func ensureModelAvailabilityHints(for transcriber: SpeechTranscriber, locale: Locale) async {
        #if canImport(Speech) && ENABLE_NATIVE_SPEECH_ANALYZER
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        let identifier = locale.identifier(.bcp47)
        if !installed.contains(identifier) {
            logger.notice("Assets for locale=\(identifier) not installed yet; the system may prompt to download them.")
        }
        #endif
    }
}
