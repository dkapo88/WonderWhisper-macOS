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
