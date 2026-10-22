import Foundation

/// How much silence to write into retained audio before a chunk, so the saved file stays on the
/// same timeline as live capture when a source pauses (for example during a microphone route
/// change). Mute ranges and recovered transcript times are then right after the pause too.
enum MeetingAudioGapPadding {
  /// Pauses shorter than this are clock jitter, not gaps.
  static let minimumGap: TimeInterval = 0.03
  /// A pause longer than this is padded only up to it, so a broken clock cannot fill the disk.
  static let maximumGap: TimeInterval = 600

  /// Samples of silence to write before a chunk starting at `chunkStart`, when the audio
  /// written so far ends at `writtenEnd` (both capture times in seconds).
  static func silenceSamples(
    writtenEnd: TimeInterval,
    chunkStart: TimeInterval,
    sampleRate: Int
  ) -> Int {
    guard chunkStart.isFinite, writtenEnd.isFinite else { return 0 }
    let gap = chunkStart - writtenEnd
    guard gap > minimumGap else { return 0 }
    return Int((min(gap, maximumGap) * Double(sampleRate)).rounded())
  }
}
