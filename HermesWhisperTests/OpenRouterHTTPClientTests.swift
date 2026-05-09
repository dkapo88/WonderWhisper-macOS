import Foundation
import Testing
@testable import HermesWhisper

struct OpenRouterHTTPClientTests {
  @Test func chatRequestDisablesReasoningByDefault() throws {
    let request = OpenRouterHTTPClient.ChatRequest(
      model: "openai/gpt-5.2",
      messages: [
        .init(role: "user", text: "Clean up this transcript.", attachment: nil)
      ],
      temperature: 0.2,
      stream: nil,
      provider: nil
    )
    let data = try JSONEncoder().encode(request)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let reasoning = try #require(object["reasoning"] as? [String: Any])

    #expect(reasoning["effort"] as? String == "none")
    #expect(reasoning["exclude"] as? Bool == true)
  }
}
