import Foundation
import AppKit
import ScreenCaptureKit
import OSLog
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CoreMedia
import Vision
import NaturalLanguage

struct ScreenCaptureSnapshot {
  enum Method: String, Codable {
    case window = "Image-Window"
    case display = "Image-Display"
  }

  let data: Data
  let mimeType: String
  let width: Int
  let height: Int
  let method: Method
  let suggestedFilename: String
}

final class ScreenCaptureService: NSObject {
  private static let signposter = OSSignposter(logger: AppLog.screen)
  private let sampleQueue = DispatchQueue(label: "ScreenCaptureService.Sample", qos: .userInitiated)

  func captureActiveWindowImage() async -> ScreenCaptureSnapshot? {
    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }

    do {
      let sid = Self.signposter.makeSignpostID()
      let state = Self.signposter.beginInterval("SCShareableContent.current", id: sid)
      let content = try await SCShareableContent.current
      Self.signposter.endInterval("SCShareableContent.current", state)

      if let window = frontmostWindow(in: content),
         let snapshot = try await captureWindow(window) {
        return snapshot
      }

      let mainID = CGMainDisplayID()
      if let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first,
         let snapshot = try await captureDisplay(display) {
        return snapshot
      }
    } catch {
      AppLog.screen.error("Screen capture failed: \(error.localizedDescription)")
    }

    return nil
  }
}

// MARK: - Private helpers
private extension ScreenCaptureService {
  func frontmostWindow(in content: SCShareableContent) -> SCWindow? {
    guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = frontmost.processIdentifier

    let candidates = content.windows.filter {
      $0.owningApplication?.processID == pid && $0.isOnScreen
    }

    if candidates.isEmpty { return nil }

    // Prefer windows that roughly match standard document-style sizing
    let minimumSize = CGSize(width: 320, height: 240)
    let filtered = candidates.filter {
      $0.frame.width >= minimumSize.width && $0.frame.height >= minimumSize.height
    }

    let meaningfulTitleWindows = filtered.filter { ($0.title?.count ?? 0) > 3 }
    if let window = meaningfulTitleWindows.max(by: { $0.frame.area < $1.frame.area }) {
      return window
    }

    if let window = filtered.max(by: { $0.frame.area < $1.frame.area }) {
      return window
    }

    return candidates.max(by: { $0.frame.area < $1.frame.area })
  }

  func captureWindow(_ window: SCWindow) async throws -> ScreenCaptureSnapshot? {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let config = SCStreamConfiguration()
    let scale = screenScale(for: window.frame)
    let width = Int((window.frame.width * scale).rounded())
    let height = Int((window.frame.height * scale).rounded())

    config.width = max(1, width)
    config.height = max(1, height)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.queueDepth = 1
    config.pixelFormat = kCVPixelFormatType_32BGRA

    return try await capture(filter: filter, configuration: config, method: .window)
  }

  func captureDisplay(_ display: SCDisplay) async throws -> ScreenCaptureSnapshot? {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = Int(display.width)
    config.height = Int(display.height)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.queueDepth = 1
    config.pixelFormat = kCVPixelFormatType_32BGRA

    return try await capture(filter: filter, configuration: config, method: .display)
  }

  func capture(filter: SCContentFilter,
               configuration: SCStreamConfiguration,
               method: ScreenCaptureSnapshot.Method) async throws -> ScreenCaptureSnapshot? {
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    var continuationHolder: AsyncStream<CMSampleBuffer>.Continuation?
    let sampleStream = AsyncStream<CMSampleBuffer> { continuation in
      continuationHolder = continuation
    }

    let output = OneShotOutput { sample in
      continuationHolder?.yield(sample)
      continuationHolder?.finish()
    }

    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
    try await stream.startCapture()

    var iterator = sampleStream.makeAsyncIterator()
    let deadline = Date().addingTimeInterval(0.6)
    var sample: CMSampleBuffer? = nil
    while Date() < deadline {
      if let value = await iterator.next() {
        sample = value
        break
      }
      try? await Task.sleep(nanoseconds: 10_000_000) // 10ms polling while waiting
    }

    continuationHolder?.finish()
    try await stream.stopCapture()
    try? stream.removeStreamOutput(output, type: .screen)

    guard let sample else {
      AppLog.screen.error("Timed out waiting for screen sample")
      return nil
    }

    return convert(sample: sample, method: method)
  }

  func convert(sample: CMSampleBuffer, method: ScreenCaptureSnapshot.Method) -> ScreenCaptureSnapshot? {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
      AppLog.screen.error("Failed to read pixel buffer from sample")
      return nil
    }

    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
      AppLog.screen.error("Failed to build CGImage from pixel buffer")
      return nil
    }

    if UserDefaults.standard.bool(forKey: "screenCapture.saveImages") {
      saveDebugImage(cgImage, prefix: "capture")
    }

    return compress(image: cgImage, method: method)
  }

  func compress(image: CGImage, method: ScreenCaptureSnapshot.Method) -> ScreenCaptureSnapshot? {
    let maxDimension: CGFloat = 1920
    let compression: CGFloat = 0.8

    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let maxSide = max(width, height)
    var scaledImage = image

    if maxSide > maxDimension {
      let scale = maxDimension / maxSide
      let scaledSize = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
      guard let downsized = downscale(image: image, to: scaledSize) else {
        AppLog.screen.warning("Downscale failed; using original image")
        scaledImage = image
        return encode(image: scaledImage, method: method, compression: compression)
      }
      scaledImage = downsized
    }

    return encode(image: scaledImage, method: method, compression: compression)
  }

  func encode(image: CGImage, method: ScreenCaptureSnapshot.Method, compression: CGFloat) -> ScreenCaptureSnapshot? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
      AppLog.screen.error("Failed to create image destination for JPEG")
      return nil
    }

    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compression]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      AppLog.screen.error("Failed to finalize JPEG encoding")
      return nil
    }

    let fileName = "screen-\(Int(Date().timeIntervalSince1970)).jpg"
    return ScreenCaptureSnapshot(
      data: data as Data,
      mimeType: "image/jpeg",
      width: image.width,
      height: image.height,
      method: method,
      suggestedFilename: fileName
    )
  }

  func downscale(image: CGImage, to size: CGSize) -> CGImage? {
    guard
      let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: image.bitsPerComponent,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return nil
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(origin: .zero, size: size))
    return context.makeImage()
  }

  func saveDebugImage(_ image: CGImage, prefix: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    let timestamp = formatter.string(from: Date())
    let filename = "\(prefix)_\(timestamp).png"

    guard
      let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
      let destination = CGImageDestinationCreateWithURL(desktop.appendingPathComponent(filename) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
      return
    }

    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    AppLog.screen.info("Saved debug capture: \(filename)")
  }

  func screenScale(for frame: CGRect) -> CGFloat {
    if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
      return screen.backingScaleFactor
    }
    return NSScreen.main?.backingScaleFactor ?? 2.0
  }

}

extension ScreenCaptureService {
    func recognizeText(from snapshot: ScreenCaptureSnapshot, preferAccurate: Bool) async -> String? {
    await Task.detached(priority: .userInitiated) {
      guard let source = CGImageSourceCreateWithData(snapshot.data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        AppLog.screen.error("Failed to decode snapshot for text recognition")
        return nil
      }

      let request = VNRecognizeTextRequest()
      request.recognitionLevel = preferAccurate ? .accurate : .fast
      request.usesLanguageCorrection = true
      if #available(macOS 13.0, *) {
        request.revision = VNRecognizeTextRequestRevision3
      }

      let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
      do {
        try handler.perform([request])
        guard let observations = request.results else { return nil }

        let blocks: [ScreenTextBlock] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ScreenTextBlock(text: trimmed, boundingBox: observation.boundingBox)
        }

        let formatter = StructuredScreenTextBuilder(blocks: blocks)
        return formatter.build()
      } catch {
        AppLog.screen.error("Text recognition failed: \(error.localizedDescription)")
        return nil
      }
    }.value
  }
}

struct ScreenTextBlock {
  let text: String
  let boundingBox: CGRect
}

struct StructuredScreenTextBuilder {
  private let blocks: [ScreenTextBlock]

  init(blocks: [ScreenTextBlock]) {
    self.blocks = blocks
  }

  func build() -> String? {
    let lines = normalize(blocks: blocks)
    guard !lines.isEmpty else { return nil }
    let paragraphs = buildParagraphs(from: lines)
    guard !paragraphs.isEmpty else { return nil }

    var sections = paragraphs.map { $0.displayText.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    let aggregateRaw = paragraphs.map { $0.rawText }.joined(separator: " ")
    let keyTerms = extractKeyTerms(from: aggregateRaw)
    if !keyTerms.isEmpty {
      sections.append("Key Terms: " + keyTerms.joined(separator: ", "))
    }

    let output = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return output.isEmpty ? nil : output
  }

  private func normalize(blocks: [ScreenTextBlock]) -> [ScreenTextLine] {
    return blocks.compactMap { block in
      let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      return ScreenTextLine(text: trimmed, boundingBox: block.boundingBox)
    }.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
  }

  private func buildParagraphs(from lines: [ScreenTextLine]) -> [StructuredParagraph] {
    guard !lines.isEmpty else { return [] }
    let heights = lines.map { max($0.height, 0.005) }
    let medianHeight = heights.medianValue ?? 0.02
    let paragraphGap = medianHeight * 1.8
    let columnThreshold: CGFloat = 0.33

    var groups: [[ScreenTextLine]] = []
    var current: [ScreenTextLine] = []
    var previous: ScreenTextLine?

    for line in lines {
      defer { previous = line }
      guard let prev = previous else {
        current.append(line)
        continue
      }

      let gap = max(0, prev.minY - line.maxY)
      let headingBreak = line.isHeading && !prev.isHeading
      let columnBreak = abs(prev.minX - line.minX) > columnThreshold &&
        prev.listContent == nil && line.listContent == nil
      if (gap > paragraphGap || headingBreak || columnBreak), !current.isEmpty {
        groups.append(current)
        current = []
      }

      current.append(line)
    }

    if !current.isEmpty { groups.append(current) }
    return groups.compactMap { renderParagraph(from: $0) }
  }

  private func renderParagraph(from lines: [ScreenTextLine]) -> StructuredParagraph? {
    let meaningful = lines.filter { !$0.trimmed.isEmpty }
    guard !meaningful.isEmpty else { return nil }

    var working = meaningful
    var heading: String? = nil
    if let first = working.first, first.isHeading {
      heading = first.trimmed
      working.removeFirst()
    }

    var sections: [String] = []
    var rawPieces: [String] = []
    var plainAccumulator = ""
    var bulletAccumulator: [String] = []

    func flushPlain() {
      let collapsed = plainAccumulator.collapsingWhitespace()
      if !collapsed.isEmpty {
        sections.append(collapsed)
        rawPieces.append(collapsed)
      }
      plainAccumulator = ""
    }

    func flushBullets() {
      guard !bulletAccumulator.isEmpty else { return }
      let bulletSection = bulletAccumulator.joined(separator: "\n")
      sections.append(bulletSection)
      rawPieces.append(bulletAccumulator.joined(separator: " "))
      bulletAccumulator.removeAll()
    }

    for line in working {
      if let bullet = line.listContent {
        flushPlain()
        bulletAccumulator.append("• \(bullet.body)")
        continue
      }

      flushBullets()
      let text = line.trimmed
      guard !text.isEmpty else { continue }
      if plainAccumulator.isEmpty {
        plainAccumulator = text
      } else if plainAccumulator.hasSuffix("-") {
        plainAccumulator.removeLast()
        plainAccumulator += text
      } else if [",", ".", ":", ";"].contains(text.first) {
        plainAccumulator += text
      } else {
        plainAccumulator += " " + text
      }
    }

    flushPlain()
    flushBullets()

    var displayComponents: [String] = []
    var rawComponents: [String] = []
    if let heading {
      displayComponents.append(heading)
      rawComponents.append(heading)
    }
    displayComponents.append(contentsOf: sections)
    rawComponents.append(contentsOf: rawPieces)

    let display = displayComponents.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let raw = rawComponents.joined(separator: " ").collapsingWhitespace()
    guard !display.isEmpty else { return nil }
    return StructuredParagraph(displayText: display, rawText: raw)
  }

  private func extractKeyTerms(from text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = trimmed
    var counts: [String: Int] = [:]
    let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]
    tagger.enumerateTags(in: trimmed.startIndex..<trimmed.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
      guard let tag, tag != .other else { return true }
      let token = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty else { return true }
      counts[token, default: 0] += 1
      return true
    }

    var ordered = counts.sorted { lhs, rhs in
      if lhs.value == rhs.value { return lhs.key.lowercased() < rhs.key.lowercased() }
      return lhs.value > rhs.value
    }.map(\.key)

    if ordered.count < 6 {
      let fallback = fallbackKeyTerms(from: trimmed)
      for term in fallback where !ordered.contains(term) {
        ordered.append(term)
        if ordered.count >= 6 { break }
      }
    }

    return Array(ordered.prefix(6))
  }

  private func fallbackKeyTerms(from text: String) -> [String] {
    var seen = Set<String>()
    var terms: [String] = []
    let separators = CharacterSet.whitespacesAndNewlines
    for raw in text.components(separatedBy: separators) {
      let token = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
      guard token.count >= 3, let first = token.first, first.isUppercase else { continue }
      let canonical = token.lowercased()
      if seen.insert(canonical).inserted {
        terms.append(token)
      }
    }
    return terms
  }
}

private struct ScreenTextLine {
  let text: String
  let boundingBox: CGRect

  var trimmed: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var minX: CGFloat { boundingBox.minX }
  var minY: CGFloat { boundingBox.minY }
  var maxY: CGFloat { boundingBox.maxY }
  var height: CGFloat { max(boundingBox.height, 0) }

  var isHeading: Bool {
    guard listContent == nil else { return false }
    let value = trimmed
    guard value.count >= 3, value.count <= 70 else { return false }
    if value.hasSuffix(":") { return true }
    let letters = value.filter { $0.isLetter }
    guard !letters.isEmpty else { return false }
    let upperCount = letters.filter { $0.isUppercase }.count
    return Double(upperCount) / Double(letters.count) > 0.75
  }

  var listContent: (marker: String, body: String)? {
    let value = trimmed
    guard !value.isEmpty else { return nil }
    let bulletChars: Set<Character> = ["-", "–", "—", "•", "*", "·", "▪", "◦"]
    if let first = value.first, bulletChars.contains(first) {
      let remainder = value.dropFirst().trimmingCharacters(in: .whitespaces)
      guard !remainder.isEmpty else { return nil }
      return (String(first), remainder)
    }

    var idx = value.startIndex
    var prefix = ""
    while idx < value.endIndex, value[idx].isNumber {
      prefix.append(value[idx])
      idx = value.index(after: idx)
    }
    if !prefix.isEmpty, idx < value.endIndex, [".", ")", "]"].contains(value[idx]) {
      let marker = prefix + String(value[idx])
      idx = value.index(after: idx)
      let remainder = value[idx...].trimmingCharacters(in: .whitespaces)
      guard !remainder.isEmpty else { return nil }
      return (marker, remainder)
    }

    idx = value.startIndex
    if idx < value.endIndex, value[idx].isLetter {
      let letter = value[idx]
      let next = value.index(after: idx)
      if next < value.endIndex, [".", ")"].contains(value[next]) {
        let marker = "\(letter)\(value[next])"
        let remainderIndex = value.index(after: next)
        let remainder = value[remainderIndex...].trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }
        return (marker, remainder)
      }
    }

    return nil
  }
}

private struct StructuredParagraph {
  let displayText: String
  let rawText: String
}

private extension Array where Element == CGFloat {
  var medianValue: CGFloat? {
    guard !isEmpty else { return nil }
    let sorted = self.sorted()
    if sorted.count % 2 == 1 {
      return sorted[sorted.count / 2]
    }
    let upperIndex = sorted.count / 2
    return (sorted[upperIndex - 1] + sorted[upperIndex]) / 2.0
  }
}

private extension String {
  func collapsingWhitespace() -> String {
    let pieces = components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
    return pieces.joined(separator: " ")
  }
}

private extension CGRect {
  var area: CGFloat { width * height }
}

private final class OneShotOutput: NSObject, SCStreamOutput {
  let handler: (CMSampleBuffer) -> Void

  init(handler: @escaping (CMSampleBuffer) -> Void) {
    self.handler = handler
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
    guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
    handler(sampleBuffer)
  }
}

extension ScreenCaptureSnapshot {
  func asAttachment(detail: LLMImageAttachment.Detail = .high) -> LLMImageAttachment {
    LLMImageAttachment(data: data, mimeType: mimeType, detail: detail, filename: suggestedFilename)
  }
}
