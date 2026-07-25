import Foundation
import Testing
@testable import WonderWhisper

struct CodexIntegrationTests {
  @Test func taskDirectoryUsesDateFolderAndPromptSlug() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let date = Date(timeIntervalSince1970: 1_704_067_200)
    let task = try CodexTaskDirectory.create(
      root: root.path,
      prompt: "Fix the Codex response window routing, please!",
      date: date
    )

    #expect(task.deletingLastPathComponent().lastPathComponent == "2024-01-01")
    #expect(task.lastPathComponent == "fix-the-codex-response-window-routing-please")
    #expect(FileManager.default.fileExists(atPath: task.path))
  }

  @Test func promptSlugIsBoundedAndHasAFallback() {
    #expect(CodexTaskDirectory.slug("...") == "voice-task")
    #expect(CodexTaskDirectory.slug(String(repeating: "word ", count: 30)).count <= 64)
  }

  @Test func desktopIPCFramePrefixesLittleEndianJSONLength() throws {
    let frame = try CodexDesktopIPCFrame.encode(["method": "initialize"])
    let length = Int(frame[0])
      | (Int(frame[1]) << 8)
      | (Int(frame[2]) << 16)
      | (Int(frame[3]) << 24)
    let payload = frame.dropFirst(4)
    let object = try JSONSerialization.jsonObject(with: payload) as? [String: String]

    #expect(length == payload.count)
    #expect(object?["method"] == "initialize")
  }

}
