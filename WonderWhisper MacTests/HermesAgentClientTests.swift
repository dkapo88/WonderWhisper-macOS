import Foundation
import Testing
@testable import WonderWhisper_Mac

struct HermesAgentClientTests {
  @Test func responsesParserExtractsAssistantOutputText() throws {
    let json = """
    {
      "id": "resp_abc123",
      "object": "response",
      "status": "completed",
      "model": "hermes-agent",
      "output": [
        {
          "type": "function_call",
          "name": "terminal",
          "arguments": "{}",
          "call_id": "call_1"
        },
        {
          "type": "message",
          "role": "assistant",
          "content": [
            {"type": "output_text", "text": "Hermes response"}
          ]
        }
      ]
    }
    """.data(using: .utf8)!

    let text = try HermesAgentAPIClient.extractOutputText(from: json)

    #expect(text == "Hermes response")
  }

  @Test func hermesSettingsFallbackToDefaultsWhenEmpty() {
    let settings = HermesAgentSettings(
      baseURLString: " ",
      model: "",
      conversationName: "\n",
      timeout: 180
    )

    #expect(settings.normalizedBaseURLString == AppConfig.defaultHermesBaseURLString)
    #expect(settings.normalizedModel == AppConfig.defaultHermesModel)
    #expect(settings.normalizedConversationName == AppConfig.defaultHermesConversationName)
  }

  @Test func hermesTimeoutLimitsAllowThirtyMinutes() {
    #expect(HermesAgentSettings.minimumTimeout == 15)
    #expect(HermesAgentSettings.maximumTimeout == 1_800)
    #expect(HermesAgentSettings.defaultTimeout == 180)
    #expect(HermesAgentSettings.clampedTimeout(5) == 15)
    #expect(HermesAgentSettings.clampedTimeout(2_400) == 1_800)
  }

  @Test func hermesEndpointsAcceptRootOrV1BaseURLs() throws {
    #expect(
      try HermesAgentAPIClient.endpointURL(
        path: "responses",
        baseURLString: "http://127.0.0.1:8642"
      ).absoluteString == "http://127.0.0.1:8642/v1/responses"
    )
    #expect(
      try HermesAgentAPIClient.endpointURL(
        path: "responses",
        baseURLString: "http://127.0.0.1:8642/v1"
      ).absoluteString == "http://127.0.0.1:8642/v1/responses"
    )
  }

  @Test func requestBodyUsesPlainTextInputWithoutImageAttachment() throws {
    let data = try HermesAgentAPIClient.requestBodyData(
      input: "Summarise this",
      settings: HermesAgentSettings(
        baseURLString: "http://127.0.0.1:8642",
        model: "hermes-agent",
        conversationName: "wonderwhisper-mac",
        timeout: 180
      ),
      imageAttachment: nil,
      clipboardText: nil
    )
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["input"] as? String == "Summarise this")
  }

  @Test func requestBodyIncludesClipboardTextInPlainInput() throws {
    let data = try HermesAgentAPIClient.requestBodyData(
      input: "Send this to Sarah",
      settings: HermesAgentSettings(
        baseURLString: "http://127.0.0.1:8642",
        model: "hermes-agent",
        conversationName: "wonderwhisper-mac",
        timeout: 180
      ),
      imageAttachment: nil,
      clipboardText: "https://example.com/reference"
    )
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let input = try #require(object["input"] as? String)

    #expect(input.contains("Send this to Sarah"))
    #expect(input.contains(HermesAgentAPIClient.clipboardContextHeader))
    #expect(input.contains("https://example.com/reference"))
  }

  @Test func requestBodyIncludesScreenshotAttachmentAndFootnote() throws {
    let attachment = HermesAgentImageAttachment(
      data: Data([0x01, 0x02, 0x03]),
      mimeType: "image/jpeg",
      width: 640,
      height: 480,
      method: .window,
      suggestedFilename: "screen.jpg"
    )
    let data = try HermesAgentAPIClient.requestBodyData(
      input: "What should I do next?",
      settings: HermesAgentSettings(
        baseURLString: "http://127.0.0.1:8642",
        model: "hermes-agent",
        conversationName: "wonderwhisper-mac",
        timeout: 180
      ),
      imageAttachment: attachment,
      clipboardText: "Copied link"
    )
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let input = try #require(object["input"] as? [[String: Any]])
    let message = try #require(input.first)
    let content = try #require(message["content"] as? [[String: Any]])
    let textPart = try #require(content.first)
    let imagePart = try #require(content.last)

    #expect(message["role"] as? String == "user")
    #expect((textPart["text"] as? String)?.contains(HermesAgentAPIClient.screenshotFootnote) == true)
    #expect((textPart["text"] as? String)?.contains(HermesAgentAPIClient.clipboardContextHeader) == true)
    #expect((textPart["text"] as? String)?.contains("Copied link") == true)
    #expect(imagePart["type"] as? String == "input_image")
    #expect((imagePart["image_url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
  }
}
