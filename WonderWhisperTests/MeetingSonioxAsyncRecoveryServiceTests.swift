import Foundation
import Testing
@testable import WonderWhisper

struct MeetingSonioxAsyncRecoveryServiceTests {
  @Test func asyncRecoveryOrdersRawSegmentsAndMapsDiarizedTokens() throws {
    let filenames = try MeetingSonioxAsyncRecoveryService.orderedSegmentFilenames(
      audioFilenames: [
        "system-0002.caf",
        "microphone-0001.caf",
        "system-0001.caf",
        "microphone-0002.caf"
      ]
    )
    #expect(filenames[.microphone] == ["microphone-0001.caf", "microphone-0002.caf"])
    #expect(filenames[.systemAudio] == ["system-0001.caf", "system-0002.caf"])

    let payload = Data("""
    {
      "tokens": [
        {"text":" Hello","start_ms":120,"end_ms":420,"speaker":"2"},
        {"text":" world","start_ms":420,"end_ms":710,"speaker":"2"},
        {"text":"<fin>"}
      ]
    }
    """.utf8)
    let systemTokens = try MeetingSonioxAsyncRecoveryService.transcriptTokens(
      from: payload,
      source: .systemAudio
    )
    let microphoneTokens = try MeetingSonioxAsyncRecoveryService.transcriptTokens(
      from: payload,
      source: .microphone
    )

    #expect(systemTokens.count == 2)
    #expect(systemTokens[0].startTime == 0.12)
    #expect(systemTokens[1].endTime == 0.71)
    #expect(systemTokens.allSatisfy { $0.speaker == "2" })
    #expect(microphoneTokens.allSatisfy { $0.speaker == nil })
  }
}
