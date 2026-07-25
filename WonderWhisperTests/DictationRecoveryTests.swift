import Foundation
import Testing
@testable import WonderWhisper

/// Guards the empty-transcript recovery path. A Soniox dictation once saved a 64s recording with
/// an empty transcript: the stream produced no tokens, and the file fallback then asked Groq for
/// model `soniox-streaming`, which 404s. Reprocess could not repair it either, because it keyed
/// off the engine name rather than whether the transcript was usable.
struct DictationRecoveryTests {
  private func settings(model: String) -> TranscriptionSettings {
    TranscriptionSettings(
      endpoint: AppConfig.xaiSpeechToTextStreaming,
      model: model,
      timeout: 30,
      language: "en",
      vocabularyTerms: ["Hapana"],
      context: "hotkey"
    )
  }

  private func entry(transcript: String, model: String?) -> HistoryEntry {
    HistoryEntry(
      id: UUID(),
      date: Date(),
      appName: nil,
      bundleID: nil,
      transcript: transcript,
      output: "",
      transcriptionModel: model
    )
  }

  // MARK: - Fix 1: recovery must use a file-capable model, not the streaming engine id

  @Test func sonioxRecoveryRewritesModelToGroqWhisper() {
    let recovery = DictationController.fileRecoverySettings(from: settings(model: "soniox-streaming"))

    // "soniox-streaming" is not a Groq model; sending it verbatim returns 404 model_not_found.
    #expect(recovery.model == AppConfig.defaultTranscriptionModel)
    #expect(recovery.endpoint == AppConfig.groqAudioTranscriptions)
  }

  @Test func xaiStreamingRecoveryRewritesToFileEngine() {
    let recovery = DictationController.fileRecoverySettings(
      from: settings(model: AppConfig.defaultXAIStreamingTranscriptionModel)
    )

    #expect(recovery.model == AppConfig.defaultXAITranscriptionModel)
    #expect(recovery.endpoint == AppConfig.xaiSpeechToText)
  }

  @Test func recoveryPreservesLanguageVocabularyAndTimeout() {
    let recovery = DictationController.fileRecoverySettings(from: settings(model: "soniox-streaming"))

    #expect(recovery.language == "en")
    #expect(recovery.vocabularyTerms == ["Hapana"])
    #expect(recovery.timeout == 30)
  }

  @Test func fileCapableEngineIsLeftAlone() {
    let original = settings(model: "whisper-large-v3-turbo")
    let recovery = DictationController.fileRecoverySettings(from: original)

    #expect(recovery.model == original.model)
    #expect(recovery.endpoint == original.endpoint)
  }

  // MARK: - Fix 2: reprocess must re-transcribe an empty entry that still has audio

  @Test func emptyStreamingEntryWithAudioIsReTranscribed() {
    let shouldUseSavedTranscript = DictationController.shouldReprocessSavedTranscriptOnly(
      entry: entry(transcript: "", model: "soniox-streaming"),
      currentTranscriptionModel: "soniox-streaming",
      hasAudio: true
    )

    // Previously true, which re-ran the LLM on "" forever and never read the good audio.
    #expect(shouldUseSavedTranscript == false)
  }

  @Test func whitespaceOnlyTranscriptCountsAsEmpty() {
    let shouldUseSavedTranscript = DictationController.shouldReprocessSavedTranscriptOnly(
      entry: entry(transcript: "   \n ", model: "soniox-streaming"),
      currentTranscriptionModel: "soniox-streaming",
      hasAudio: true
    )

    #expect(shouldUseSavedTranscript == false)
  }

  @Test func usableStreamingTranscriptStillSkipsReTranscription() {
    // The 2026-05-21 behaviour must survive: a good realtime transcript is LLM-only.
    let shouldUseSavedTranscript = DictationController.shouldReprocessSavedTranscriptOnly(
      entry: entry(transcript: "Hello there.", model: "soniox-streaming"),
      currentTranscriptionModel: "soniox-streaming",
      hasAudio: true
    )

    #expect(shouldUseSavedTranscript == true)
  }

  @Test func emptyEntryWithoutAudioCannotBeReTranscribed() {
    let shouldUseSavedTranscript = DictationController.shouldReprocessSavedTranscriptOnly(
      entry: entry(transcript: "", model: "soniox-streaming"),
      currentTranscriptionModel: "soniox-streaming",
      hasAudio: false
    )

    #expect(shouldUseSavedTranscript == true)
  }
}
