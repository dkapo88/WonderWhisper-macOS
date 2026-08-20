import Testing
import Foundation
@testable import WonderWhisper

struct SimpleModeModelTests {
  @Test func xaiAsyncAndStreamingEnginesUseDistinctModelIDs() {
    #expect(SimpleVoiceEngine.xaiSpeechToText.transcriptionModel == "xai-stt")
    #expect(SimpleVoiceEngine.xaiStreamingSpeechToText.transcriptionModel == "xai-stt-streaming")
    #expect(SimpleVoiceEngine.xaiStreamingSpeechToText.transcriptionModel == AppConfig.defaultXAIStreamingTranscriptionModel)
  }

  @Test func xaiStreamingEngineUsesLiveTranscriptOverlay() {
    #expect(SimpleVoiceEngine.xaiSpeechToText.showsLiveTranscript == false)
    #expect(SimpleVoiceEngine.xaiStreamingSpeechToText.showsLiveTranscript == true)
  }

  @Test func qwenLocalEngineIsFileBasedOnDevice() {
    #expect(SimpleVoiceEngine.qwenLocal.transcriptionModel == "qwen-local")
    #expect(SimpleVoiceEngine.qwenLocal.showsLiveTranscript == false)
    #expect(QwenASRManager.isQwenModel("qwen-local"))
    #expect(QwenASRManager.isQwenModel("Qwen-Local"))
    #expect(!QwenASRManager.isQwenModel("qwen/qwen3-asr-0.6b"))
    #expect(!QwenASRManager.isQwenModel("parakeet-local"))
    #expect(QwenASRManager.languageHint(for: "auto") == nil)
    #expect(QwenASRManager.languageHint(for: "en-US") == "en")
    #expect(QwenASRManager.languageHint(for: "zh") == "zh")
    #expect(QwenASRManager.modelId.contains("0.6B"))
    #expect(SimpleVoiceEngine.qwenLocal.isAvailable == QwenASRManager.isRuntimeAvailable)
  }

  @Test func qwenDecoderContextFollowsVocabularyToggle() {
    let terms = ["Hapana", "Soniox"]
    #expect(
      QwenASRManager.decoderContext(from: terms, enabled: true)
        == "Vocabulary: Hapana, Soniox"
    )
    #expect(QwenASRManager.decoderContext(from: terms, enabled: false) == nil)
    #expect(QwenASRManager.decoderContext(from: ["  ", ""], enabled: true) == nil)
    #expect(QwenASRManager.injectVocabularyEnabled)
  }

  @Test func qwenKeepsShortAudioAsASingleDecode() {
    let rate = QwenASRManager.sampleRate
    let samples = 10 * rate
    let ranges = QwenASRManager.transcriptionChunkRanges(sampleCount: samples)
    #expect(ranges == [0..<samples])
  }

  @Test func qwenSplitsAudioLongerThanFifteenSeconds() {
    let rate = QwenASRManager.sampleRate
    let samples = 16 * rate
    let ranges = QwenASRManager.transcriptionChunkRanges(sampleCount: samples)
    #expect(ranges.count == 2)
    #expect(ranges[0].count == 15 * rate)
    #expect(ranges[1].count == rate)
  }

  @Test func qwenSplitsLongAudioIntoFifteenSecondSlices() {
    let rate = QwenASRManager.sampleRate
    let samples = 50 * rate
    let ranges = QwenASRManager.transcriptionChunkRanges(sampleCount: samples)
    #expect(ranges.count == 4)
    #expect(ranges[0].count == 15 * rate)
    #expect(ranges[3].count == 5 * rate)
    #expect(ranges.last?.upperBound == samples)
  }

  @Test func qwenWeightsExistRejectsIncompleteShardSet() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
    try Data("{}".utf8).write(to: dir.appendingPathComponent("vocab.json"))
    try Data([0]).write(to: dir.appendingPathComponent("model-00001-of-00002.safetensors"))
    let index = """
    {"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}
    """
    try Data(index.utf8).write(to: dir.appendingPathComponent("model.safetensors.index.json"))
    #expect(!QwenASRManager.weightsExist(in: dir))
  }

  @Test func sonioxStreamingEngineUsesV5RealtimeModel() {
    #expect(SimpleVoiceEngine.sonioxStreaming.displayName == "Soniox V5 (Real-time Cloud)")
    #expect(SonioxStreamingProvider.apiModel(for: "") == "stt-rt-v5")
    #expect(SonioxStreamingProvider.apiModel(for: "soniox-streaming") == "stt-rt-v5")
    #expect(SonioxStreamingProvider.apiModel(for: "stt-rt-v3") == "stt-rt-v5")
    #expect(SonioxStreamingProvider.apiModel(for: "stt-rt-v4") == "stt-rt-v5")
    #expect(SonioxStreamingProvider.apiModel(for: "stt-rt-v5") == "stt-rt-v5")
  }

  @Test func openRouterChatRequestOmitsReasoningByDefault() throws {
    let request = OpenRouterHTTPClient.ChatRequest(
      model: "google/gemini-3.5-flash",
      messages: [.init(role: "user", text: "Test", attachment: nil)],
      temperature: 0.2,
      provider: nil
    )

    let object = try encodedJSONObject(request)
    #expect(object["reasoning"] == nil)
    #expect(object["stream"] == nil)
  }

  @Test func openRouterChatRequestCanSendMinimalReasoning() throws {
    let request = OpenRouterHTTPClient.ChatRequest(
      model: "google/gemini-3.5-flash",
      messages: [.init(role: "user", text: "Test", attachment: nil)],
      temperature: 0.2,
      provider: nil,
      reasoning: .init(effort: OpenRouterReasoningMode.minimal.rawValue, exclude: true)
    )

    let object = try encodedJSONObject(request)
    let reasoning = try #require(object["reasoning"] as? [String: Any])
    #expect(reasoning["effort"] as? String == "minimal")
    #expect(reasoning["exclude"] as? Bool == true)
  }

  private func encodedJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    let object = try JSONSerialization.jsonObject(with: data)
    return try #require(object as? [String: Any])
  }
}
