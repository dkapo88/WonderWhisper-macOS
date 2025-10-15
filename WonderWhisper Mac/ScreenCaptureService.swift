import Foundation
import AppKit
import ScreenCaptureKit
import OSLog
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CoreMedia
import Vision

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
        let observations = request.results ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
      } catch {
        AppLog.screen.error("Text recognition failed: \(error.localizedDescription)")
        return nil
      }
    }.value
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
