import Foundation
import AppKit
import Vision
import ScreenCaptureKit
import OSLog
import CoreImage
import ImageIO
import UniformTypeIdentifiers

final class ScreenCaptureService: NSObject {
    private static let signposter = OSSignposter(logger: AppLog.ocr)

    private func frontmostWindow(in content: SCShareableContent) -> SCWindow? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let pid = frontApp?.processIdentifier

        // Enhanced window selection with multiple strategies
        if let pid {
            let candidates = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.isOnScreen
            }

            // Strategy 1: Find main content windows (larger than typical overlays)
            let mainWindows = candidates.filter {
                $0.frame.width >= 400 && $0.frame.height >= 300
            }

            // Strategy 2: Exclude likely system UI elements and overlays
            let contentWindows = mainWindows.filter { window in
                let title = window.title ?? ""
                let frame = window.frame

                // Exclude very small windows (likely overlays)
                if frame.width < 200 || frame.height < 150 { return false }

                // Exclude windows with system-like titles
                let systemTitles = ["", "Window", "Panel", "Menu", "Popup", "Tooltip"]
                if systemTitles.contains(title) { return false }

                // Exclude windows that are too narrow or too short (likely panels)
                let aspectRatio = frame.width / frame.height
                if aspectRatio < 0.3 || aspectRatio > 5.0 { return false }

                return true
            }

            // Strategy 3: Prefer windows with meaningful titles
            if !contentWindows.isEmpty {
                // First try to find windows with substantial titles
                let titledWindows = contentWindows.filter {
                    ($0.title?.count ?? 0) > 3
                }

                if !titledWindows.isEmpty {
                    return titledWindows.max(by: {
                        $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                    })
                }

                // Fallback to largest content window
                return contentWindows.max(by: {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                })
            }

            // Strategy 4: Fallback to any reasonable-sized window
            let reasonableWindows = candidates.filter {
                $0.frame.width >= 200 && $0.frame.height >= 150
            }

            if !reasonableWindows.isEmpty {
                return reasonableWindows.max(by: {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                })
            }

            // Strategy 5: Last resort - any visible window
            if !candidates.isEmpty {
                return candidates.max(by: {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                })
            }
        }

        // Final fallback: largest on-screen window not owned by us
        let ownPID = NSRunningApplication.current.processIdentifier
        let others = content.windows.filter {
            $0.owningApplication?.processID != ownPID && $0.isOnScreen &&
            $0.frame.width >= 200 && $0.frame.height >= 150
        }
        return others.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        })
    }

    private final class OneShotOutput: NSObject, SCStreamOutput {
        let onFrame: (CMSampleBuffer) -> Void
        init(onFrame: @escaping (CMSampleBuffer) -> Void) { self.onFrame = onFrame }
        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
            guard outputType == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
            onFrame(sampleBuffer)
        }
    }

    // Capture a single frame and OCR directly from the CVPixelBuffer
    private func captureAndRecognizeActiveWindowText() async -> String? {
        do {
            let sid = Self.signposter.makeSignpostID()
            let state_sc = Self.signposter.beginInterval("SCShareableContent.current", id: sid)
            let content = try await SCShareableContent.current
            Self.signposter.endInterval("SCShareableContent.current", state_sc)

            guard let window = frontmostWindow(in: content) else {
                if UserDefaults.standard.bool(forKey: "ocr.debug") {
                    AppLog.ocr.error("No suitable window found for OCR")
                }
                return nil
            }

            // Enhanced app detection and configuration
            let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let isCodeEditor = [
                "com.cursorai.cursor",
                "com.todesktop.cursor",
                "com.microsoft.VSCode",
                "com.microsoft.VSCodeInsiders",
                "com.apple.dt.Xcode",
                "com.jetbrains"
            ].contains(where: { frontBundle.hasPrefix($0) })

            let isBrowser = [
                "com.apple.Safari",
                "com.google.Chrome",
                "org.mozilla.firefox",
                "com.microsoft.edgemac",
                "com.operasoftware.Opera"
            ].contains(where: { frontBundle.hasPrefix($0) })

            let preferAccurate = (UserDefaults.standard.object(forKey: "ocr.accurateForEditors") as? Bool ?? true)
            let forceAccurate = UserDefaults.standard.bool(forKey: "ocr.forceAccurate")
            let shouldPreferAccurate = forceAccurate || (isCodeEditor && preferAccurate) || isBrowser

            // Enhanced debugging
            if UserDefaults.standard.bool(forKey: "ocr.debug") {
                let title = window.title ?? "(no title)"
                let f = window.frame
                let bid = window.owningApplication?.bundleIdentifier ?? "(unknown)"
                AppLog.ocr.info("OCR target: '\(title)' (\(Int(f.width))x\(Int(f.height))) app=\(bid) editor=\(isCodeEditor) browser=\(isBrowser) accurate=\(shouldPreferAccurate)")
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let size = window.frame.size

            // Capture at native scaled size (avoid upscaling to prevent blur)
            let scale = NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2.0

            let scaledWidth = Int((size.width * scale).rounded())
            let scaledHeight = Int((size.height * scale).rounded())

            config.width = scaledWidth
            config.height = scaledHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 1

            // Validate capture configuration
            if UserDefaults.standard.bool(forKey: "ocr.debug") {
                AppLog.ocr.info("Capture config: \(config.width)x\(config.height) scale=\(scale)")
            }

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            // Await the first processed frame or a timeout via AsyncStream
            var textContinuation: AsyncStream<String?>.Continuation?
            let textStream = AsyncStream<String?> { continuation in
                textContinuation = continuation
            }

            // Enhanced OCR configuration with app-specific optimizations
            let userMinH = UserDefaults.standard.object(forKey: "ocr.minimumTextHeight") as? Double
            let dynamicMinHeight = calculateMinimumTextHeight(
                imageWidth: config.width,
                imageHeight: config.height,
                isCodeEditor: isCodeEditor,
                isBrowser: isBrowser,
                userOverride: userMinH
            )

            // Primary OCR request with optimized settings
            let primaryReq = VNRecognizeTextRequest { _, _ in }
            primaryReq.recognitionLevel = shouldPreferAccurate ? .accurate : .fast
            primaryReq.usesLanguageCorrection = isBrowser ? true : (!isCodeEditor)
            primaryReq.minimumTextHeight = max(0.0008, dynamicMinHeight * (config.width < 900 ? 0.5 : 1.0))

            // Configure for better text detection
            if #available(macOS 13.0, *) {
                primaryReq.revision = VNRecognizeTextRequestRevision3
            }

            // Fallback OCR request with different settings
            let fallbackReq = VNRecognizeTextRequest { _, _ in }
            fallbackReq.recognitionLevel = .accurate
            fallbackReq.usesLanguageCorrection = false
            fallbackReq.minimumTextHeight = max(0.0, primaryReq.minimumTextHeight * 0.5) // More permissive

            if #available(macOS 13.0, *) {
                fallbackReq.revision = VNRecognizeTextRequestRevision3
            }

            let queue = DispatchQueue(label: "ScreenCaptureService.SampleHandler", qos: .userInitiated)
            let output = OneShotOutput { sample in
                if let text = self.processSample(
                    sample,
                    primaryReq: primaryReq,
                    fallbackReq: fallbackReq,
                    isCodeEditor: isCodeEditor,
                    isBrowser: isBrowser,
                    shouldPreferAccurate: shouldPreferAccurate
                ) {
                    textContinuation?.yield(text)
                    textContinuation?.finish()
                }
            }

            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()

            // Enhanced timeout logic with better defaults
            let extendedTimeout = UserDefaults.standard.bool(forKey: "ocr.extendedTimeout")
            let baseTimeout: TimeInterval = extendedTimeout ? 2.0 : (shouldPreferAccurate ? 1.0 : 0.5)
            let timeoutNanos: UInt64 = UInt64(baseTimeout * 1_000_000_000)

            let result: String? = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    for await t in textStream { return t }
                    return nil
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanos)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }

            // Finish and stop capture
            textContinuation?.finish()
            try await stream.stopCapture()

            if UserDefaults.standard.bool(forKey: "ocr.debug") && result == nil {
                AppLog.ocr.warning("OCR timeout after \(baseTimeout)s - no text captured")
            }

            return result
        } catch {
            if UserDefaults.standard.bool(forKey: "ocr.debug") {
                AppLog.ocr.error("Screen capture failed: \(error.localizedDescription)")
            }
            return nil
        }
    }

    func captureActiveWindowText() async -> String? {
        // Try to prompt for Screen Recording permission on first attempt
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        return await captureAndRecognizeActiveWindowText()
    }

    // MARK: - Helper Methods

    private func calculateMinimumTextHeight(imageWidth: Int, imageHeight: Int, isCodeEditor: Bool, isBrowser: Bool, userOverride: Double?) -> Float {
        if let override = userOverride {
            return Float(override)
        }

        // Dynamic minimum text height based on image size and app type
        let imageArea = Double(imageWidth * imageHeight)
        let baseHeight: Double

        if isCodeEditor {
            // Code editors typically have smaller, more precise text
            baseHeight = 0.003
        } else if isBrowser {
            // Browsers have varied text sizes, be more permissive
            baseHeight = 0.002
        } else {
            // General applications
            baseHeight = 0.0025
        }

        // Scale based on image resolution
        let scaleFactor = min(2.0, max(0.5, imageArea / 1_000_000.0))
        return Float(baseHeight * scaleFactor)
    }

    private func cleanTextSegment(_ text: String, confidence: Float) -> String {
        var cleaned = text

        // Remove obvious OCR artifacts
        cleaned = cleaned.replacingOccurrences(of: "�", with: "")

        // Remove isolated single characters that are likely noise (unless high confidence)
        if confidence < 0.7 && cleaned.count == 1 {
            let char = cleaned.first!
            if !char.isLetter && !char.isNumber {
                return ""
            }
        }

        // Remove segments that are mostly special characters (likely corruption)
        let alphanumericCount = cleaned.filter { $0.isLetter || $0.isNumber || $0.isWhitespace }.count
        let totalCount = cleaned.count

        if totalCount > 0 && Double(alphanumericCount) / Double(totalCount) < 0.3 && confidence < 0.6 {
            return ""
        }

        // Clean up excessive whitespace
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned
    }

    private func saveImageForDebugging(_ pixelBuffer: CVPixelBuffer, prefix: String) {
        guard let cgImage = createCGImage(from: pixelBuffer) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())

        let filename = "\(prefix)_\(timestamp).png"
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let fileURL = desktopURL.appendingPathComponent(filename)

        let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil)
        if let destination = destination {
            CGImageDestinationAddImage(destination, cgImage, nil)
            CGImageDestinationFinalize(destination)
            AppLog.ocr.info("Saved debug image: \(filename)")
        }
    }

    private func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
    private func computeQualityScore(from observations: [VNRecognizedTextObservation]?) -> (score: Double, text: String?, cleanText: String?) {
        guard let observations else { return (0, nil, nil) }
        var totalConfidence: Double = 0
        var count: Double = 0
        var rawText = ""
        var cleanedSegments: [String] = []

        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let confidence = Double(top.confidence)
            if confidence < 0.1 { continue }
            totalConfidence += confidence
            count += 1
            rawText.append(top.string)
            rawText.append("\n")
            let cleaned = self.cleanTextSegment(top.string, confidence: Float(confidence))
            if !cleaned.isEmpty { cleanedSegments.append(cleaned) }
        }
        let avgConf = count > 0 ? totalConfidence / count : 0
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = cleanedSegments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (avgConf, raw.isEmpty ? nil : raw, clean.isEmpty ? nil : clean)
    }
    private func processSample(_ sample: CMSampleBuffer,
                               primaryReq: VNRecognizeTextRequest,
                               fallbackReq: VNRecognizeTextRequest,
                               isCodeEditor: Bool,
                               isBrowser: Bool,
                               shouldPreferAccurate: Bool) -> String? {
        guard let px = CMSampleBufferGetImageBuffer(sample) else {
            if UserDefaults.standard.bool(forKey: "ocr.debug") {
                AppLog.ocr.error("Failed to get image buffer from sample")
            }
            return nil
        }

        let imageWidth = CVPixelBufferGetWidth(px)
        let imageHeight = CVPixelBufferGetHeight(px)
        if imageWidth < 100 || imageHeight < 100 {
            if UserDefaults.standard.bool(forKey: "ocr.debug") {
                AppLog.ocr.error("Image too small for OCR: \(imageWidth)x\(imageHeight)")
            }
            return nil
        }

        if UserDefaults.standard.bool(forKey: "ocr.saveImages") {
            self.saveImageForDebugging(px, prefix: "captured")
        }

        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: px, options: [:])
            // Primary
            let sid = Self.signposter.makeSignpostID()
            let state_primary = Self.signposter.beginInterval("OCR.primary", id: sid)
            try handler.perform([primaryReq])
            Self.signposter.endInterval("OCR.primary", state_primary)

            let primary = self.computeQualityScore(from: primaryReq.results)
            var bestScore: Double = primary.score
            var bestText: String? = primary.text
            var bestCleanText: String? = primary.cleanText

            let lineCount = bestText?.split(separator: "\n").count ?? 0
            let charCount = bestText?.count ?? 0
            let cleanCharCount = bestCleanText?.count ?? 0
            let goodEnough = (lineCount >= 5) || (charCount >= 50) || (cleanCharCount >= 30) || (bestScore >= 0.3)

            if !goodEnough || bestScore < 0.4 {
                let sid2 = Self.signposter.makeSignpostID()
                let state_fallback = Self.signposter.beginInterval("OCR.fallback", id: sid2)
                do {
                    try handler.perform([fallbackReq])
                    Self.signposter.endInterval("OCR.fallback", state_fallback)
                    let fallback = self.computeQualityScore(from: fallbackReq.results)
                    let betterScore = fallback.score > bestScore * 1.2
                    let fallbackCleanLen = fallback.cleanText?.count ?? 0
                    let currentCleanLen = bestCleanText?.count ?? 0
                    let betterClean = fallbackCleanLen > Int(Double(currentCleanLen) * 1.5)
                    if betterScore || betterClean {
                        bestScore = fallback.score
                        bestText = fallback.text
                        bestCleanText = fallback.cleanText
                    }
                } catch {
                    Self.signposter.endInterval("OCR.fallback", state_fallback)
                    if UserDefaults.standard.bool(forKey: "ocr.debug") {
                        AppLog.ocr.error("Fallback OCR failed: \(error.localizedDescription)")
                    }
                }
            }

            if UserDefaults.standard.bool(forKey: "ocr.debug") || UserDefaults.standard.bool(forKey: "ocr.verboseLogging") {
                AppLog.ocr.info("OCR results: \(imageWidth)x\(imageHeight) score=\(String(format: "%.3f", bestScore)) lines=\(lineCount) chars=\(charCount) clean=\(cleanCharCount) editor=\(isCodeEditor) browser=\(isBrowser) accurate=\(shouldPreferAccurate)")
                if let text = bestText, UserDefaults.standard.bool(forKey: "ocr.verboseLogging") {
                    let preview = String(text.prefix(100)).replacingOccurrences(of: "\n", with: "\\n")
                    AppLog.ocr.info("OCR preview: \(preview)")
                }
            }

            if let cleanText = bestCleanText, cleanText.count >= 10 {
                return cleanText
            } else if let rawText = bestText, !rawText.isEmpty {
                return rawText
            }
        } catch {
            if UserDefaults.standard.bool(forKey: "ocr.debug") {
                AppLog.ocr.error("OCR processing failed: \(error.localizedDescription)")
            }
        }
        return nil
    }


}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
