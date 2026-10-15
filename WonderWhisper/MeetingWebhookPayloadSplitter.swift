import Foundation

/// Splits one webhook payload into parts whose whole serialized body fits a byte limit, for
/// receivers that only keep the start of a long body.
///
/// Size is measured on the final body in UTF-8 bytes, which is never less than its UTF-16 or
/// character count, so the limit holds whatever the receiver counts. Every part carries the
/// same metadata plus `sendId` and `part`; only `note.markdown` differs. Each part's Markdown
/// ends with a blank line and `END-OF-PAYLOAD part N of M`; with that suffix removed, the
/// parts' Markdown joins back into the original exactly.
enum MeetingWebhookPayloadSplitter {
  enum SplitError: Error, Equatable {
    /// Even the smallest possible part needs `required` bytes, more than `limit`.
    case limitTooSmall(required: Int, limit: Int)

    var message: String {
      switch self {
      case let .limitTooSmall(required, limit):
        return "Max body size \(limit) is too small for this note; a part needs at least "
          + "\(required) characters."
      }
    }
  }

  /// Why a partial resend can't reproduce the parts of an earlier send.
  enum ResendError: Error, Equatable {
    /// The note, or the way it is cut, is not what was sent.
    case noteChanged
    /// The part would now be longer than the max body size (for example a longer app version).
    case partTooLarge(index: Int)

    var message: String {
      switch self {
      case .noteChanged:
        return "The note changed since it was sent; use Send to Webhook to send all parts "
          + "again."
      case let .partTooLarge(index):
        return "Part \(index) no longer fits the max body size; use Send to Webhook to send "
          + "all parts again."
      }
    }
  }

  /// The parts of one split send, plus what a later partial resend needs to cut the note the
  /// same way again.
  struct Split: Equatable, Sendable {
    let parts: [MeetingWebhookPayload]
    /// The note's Markdown in each part, without the end marker; they join back into the note.
    let chunks: [String]
    /// The escaped-byte budget each chunk was cut to.
    let chunkBudget: Int
  }

  /// A part is only cut at a preferred boundary if it is at least this full; otherwise the
  /// next, weaker kind of boundary is tried, ending with a hard cut between characters. High,
  /// so parts come out nearly full and a note needs as few requests as possible.
  static let minimumFill = 0.85

  /// The payloads to send, in order. `base` is the unsplit payload; each part gets `sendID`, a
  /// fresh delivery ID and its `part` index and total.
  static func parts(
    of base: MeetingWebhookPayload,
    sendID: UUID,
    maxBytes: Int,
    makeDeliveryID: () -> UUID = { UUID() }
  ) throws -> [MeetingWebhookPayload] {
    try split(of: base, sendID: sendID, maxBytes: maxBytes, makeDeliveryID: makeDeliveryID).parts
  }

  /// Splits `base` so every whole body, end marker included, is at most `maxBytes`.
  static func split(
    of base: MeetingWebhookPayload,
    sendID: UUID,
    maxBytes: Int,
    makeDeliveryID: () -> UUID = { UUID() }
  ) throws -> Split {
    // `part.total` and the end marker appear in every body, so size the metadata for the
    // widest index and total with `width` digits and widen until the part count fits.
    var width = 1
    while true {
      let widest = largestNumber(digits: width)
      var template = base
      template.sendId = sendID
      let widestPart = MeetingWebhookPayload.Part(index: widest, total: widest)
      template.part = widestPart
      template.note.markdown = widestPart.markdownSuffix
      let overhead = template.body.count
      guard overhead <= maxBytes else {
        throw SplitError.limitTooSmall(required: overhead, limit: maxBytes)
      }
      let budget = maxBytes - overhead
      let chunks: [String]
      do {
        chunks = try chunk(base.note.markdown, budget: budget)
      } catch let CharacterTooLarge.cost(cost) {
        throw SplitError.limitTooSmall(required: overhead + cost, limit: maxBytes)
      }
      if chunks.count <= widest {
        let parts = chunks.enumerated().map { offset, markdown in
          payload(
            base,
            sendID: sendID,
            deliveryID: makeDeliveryID(),
            index: offset + 1,
            total: chunks.count,
            chunk: markdown
          )
        }
        return Split(parts: parts, chunks: chunks, chunkBudget: budget)
      }
      width += 1
    }
  }

  /// Cuts the note exactly as an earlier send did (same `chunkBudget`) and rebuilds only the
  /// parts at `indexes`, each with a fresh delivery ID, the original `sendID` and `total`.
  /// Returns the chunks too, so the caller can compare their fingerprints with the log.
  static func resend(
    of base: MeetingWebhookPayload,
    sendID: UUID,
    chunkBudget: Int,
    total: Int,
    indexes: [Int],
    maxBytes: Int,
    makeDeliveryID: () -> UUID = { UUID() }
  ) throws -> (parts: [MeetingWebhookPayload], chunks: [String]) {
    guard chunkBudget > 0, let chunks = try? chunk(base.note.markdown, budget: chunkBudget),
          chunks.count == total else {
      throw ResendError.noteChanged
    }
    var parts: [MeetingWebhookPayload] = []
    for index in indexes {
      guard (1...total).contains(index) else { throw ResendError.noteChanged }
      let part = payload(
        base,
        sendID: sendID,
        deliveryID: makeDeliveryID(),
        index: index,
        total: total,
        chunk: chunks[index - 1]
      )
      guard part.body.count <= maxBytes else {
        throw ResendError.partTooLarge(index: index)
      }
      parts.append(part)
    }
    return (parts, chunks)
  }

  /// The chunk of a part's Markdown: the Markdown without its end-marker suffix.
  static func chunk(of part: MeetingWebhookPayload) -> String {
    guard let info = part.part else { return part.note.markdown }
    // Compare scalars, not characters: a chunk ending in "\r" merges with the suffix's "\n".
    let scalars = Array(part.note.markdown.unicodeScalars)
    let suffix = Array(info.markdownSuffix.unicodeScalars)
    guard scalars.count >= suffix.count, Array(scalars.suffix(suffix.count)) == suffix else {
      return part.note.markdown
    }
    var chunk = String.UnicodeScalarView()
    chunk.append(contentsOf: scalars.dropLast(suffix.count))
    return String(chunk)
  }

  private static func payload(
    _ base: MeetingWebhookPayload,
    sendID: UUID,
    deliveryID: UUID,
    index: Int,
    total: Int,
    chunk: String
  ) -> MeetingWebhookPayload {
    var part = base
    part.deliveryId = deliveryID
    part.sendId = sendID
    let info = MeetingWebhookPayload.Part(index: index, total: total)
    part.part = info
    part.note.markdown = chunk + info.markdownSuffix
    return part
  }

  private enum CharacterTooLarge: Error {
    case cost(Int)
  }

  private static func largestNumber(digits: Int) -> Int {
    var value = 0
    for _ in 0..<digits {
      value = value * 10 + 9
    }
    return value
  }

  /// Greedy chunks of `text` whose escaped JSON size is at most `budget` bytes each. Cuts
  /// prefer, in order: before a Markdown heading line, after a blank line, after a line break,
  /// after a sentence end, after a space, and finally between any two characters. Never cuts
  /// inside a grapheme cluster.
  static func chunks(of text: String, budget: Int) -> [String]? {
    try? chunk(text, budget: budget)
  }

  private static func chunk(_ text: String, budget: Int) throws -> [String] {
    let characters = Array(text)
    guard !characters.isEmpty else { return [""] }
    var prefix = [0]
    prefix.reserveCapacity(characters.count + 1)
    for character in characters {
      let cost = MeetingWebhookJSONValue.escapedByteCount(of: character)
      prefix.append((prefix.last ?? 0) + cost)
    }
    var result: [String] = []
    var start = 0
    while start < characters.count {
      var end = start
      while end < characters.count, prefix[end + 1] - prefix[start] <= budget {
        end += 1
      }
      guard end > start else {
        throw CharacterTooLarge.cost(prefix[start + 1] - prefix[start])
      }
      if end < characters.count {
        let minimum = Int((Double(budget) * minimumFill).rounded(.up))
        end = cutPoint(characters, start: start, limit: end) { position in
          prefix[position] - prefix[start] >= minimum
        }
      }
      result.append(String(characters[start..<end]))
      start = end
    }
    return result
  }

  /// Kinds of cut, strongest first. A cut at position `p` ends the chunk just before `p`.
  private enum Cut: CaseIterable {
    case beforeHeading
    case afterBlankLine
    case afterLineBreak
    case afterSentence
    case afterSpace

    func allows(_ chars: [Character], start: Int, at p: Int) -> Bool {
      let previous = chars[p - 1]
      switch self {
      case .beforeHeading:
        return previous.isNewline && MeetingWebhookPayloadSplitter.startsHeading(chars, at: p)
      case .afterBlankLine:
        return previous.isNewline && p - 2 >= start && chars[p - 2].isNewline
      case .afterLineBreak:
        return previous.isNewline
      case .afterSentence:
        if "\u{3002}\u{FF01}\u{FF1F}".contains(previous) { return true }
        return previous.isWhitespace && p - 2 >= start && ".!?".contains(chars[p - 2])
      case .afterSpace:
        return previous.isWhitespace
      }
    }
  }

  private static func cutPoint(
    _ characters: [Character],
    start: Int,
    limit: Int,
    isFullEnough: (Int) -> Bool
  ) -> Int {
    for cut in Cut.allCases {
      var position = limit
      while position > start, isFullEnough(position) {
        if cut.allows(characters, start: start, at: position) { return position }
        position -= 1
      }
    }
    return limit
  }

  /// Whether a Markdown ATX heading (`#` to `######` then a space or line end) starts at `index`.
  fileprivate static func startsHeading(_ characters: [Character], at index: Int) -> Bool {
    var end = index
    while end < characters.count, characters[end] == "#" {
      end += 1
    }
    let hashes = end - index
    guard (1...6).contains(hashes) else { return false }
    return end == characters.count || characters[end] == " " || characters[end].isNewline
  }
}
