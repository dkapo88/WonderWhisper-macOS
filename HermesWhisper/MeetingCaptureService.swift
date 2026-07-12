import Foundation
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import FluidAudio

struct MeetingAudioChunk: Sendable {
  let source: MeetingAudioSource
  let samples: [Float]
  let startTime: TimeInterval
  let duration: TimeInterval
}

final class MeetingAudioChunkFramer {
  static let sampleRate = 16_000
  static let frameSampleCount = 1_600

  private let source: MeetingAudioSource
  private var pendingSamples: [Float] = []
  private var nextFrameStartTime: TimeInterval?

  init(source: MeetingAudioSource) {
    self.source = source
  }

  func append(
    samples: [Float],
    startTime: TimeInterval
  ) -> [MeetingAudioChunk] {
    guard !samples.isEmpty else { return [] }
    if nextFrameStartTime == nil {
      nextFrameStartTime = max(0, startTime)
    } else if pendingSamples.isEmpty,
              startTime.isFinite,
              startTime > (nextFrameStartTime ?? startTime) + 0.03 {
      // A microphone/output route change may pause a ScreenCaptureKit source while
      // its presentation clock continues. Preserve that gap instead of assigning
      // resumed audio to a timeline the mixer has already emitted.
      nextFrameStartTime = startTime
    }
    pendingSamples.append(contentsOf: samples)
    return drain(includePartialFrame: false)
  }

  func finish() -> [MeetingAudioChunk] {
    let chunks = drain(includePartialFrame: true)
    reset()
    return chunks
  }

  func reset() {
    pendingSamples.removeAll(keepingCapacity: true)
    nextFrameStartTime = nil
  }

  private func drain(includePartialFrame: Bool) -> [MeetingAudioChunk] {
    var result: [MeetingAudioChunk] = []
    var consumedSampleCount = 0
    while pendingSamples.count - consumedSampleCount >= Self.frameSampleCount
      || (includePartialFrame && pendingSamples.count > consumedSampleCount) {
      let available = pendingSamples.count - consumedSampleCount
      let sampleCount = min(Self.frameSampleCount, available)
      guard sampleCount > 0, let startTime = nextFrameStartTime else { break }
      let endIndex = consumedSampleCount + sampleCount
      let frame = Array(pendingSamples[consumedSampleCount..<endIndex])
      let duration = Double(sampleCount) / Double(Self.sampleRate)
      result.append(
        MeetingAudioChunk(
          source: source,
          samples: frame,
          startTime: startTime,
          duration: duration
        )
      )
      consumedSampleCount = endIndex
      nextFrameStartTime = startTime + duration
    }

    if consumedSampleCount == pendingSamples.count {
      pendingSamples.removeAll(keepingCapacity: true)
    } else if consumedSampleCount > 0 {
      pendingSamples = Array(pendingSamples.dropFirst(consumedSampleCount))
    }
    return result
  }
}

enum MeetingAudioMeter {
  static func level(from samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sampleStride = max(1, samples.count / 1_024)
    var sumSquares: Float = 0
    var peak: Float = 0
    var sampleCount = 0
    for index in stride(from: 0, to: samples.count, by: sampleStride) {
      let sample = abs(samples[index])
      sumSquares += sample * sample
      peak = max(peak, sample)
      sampleCount += 1
    }
    guard sampleCount > 0 else { return 0 }
    let rms = sqrt(sumSquares / Float(sampleCount))
    let energy = rms * 0.7 + peak * 0.3
    guard energy >= 0.002 else { return 0 }
    return min(1, pow(energy * 4, 0.6))
  }
}

enum MeetingCaptureError: LocalizedError {
  case noDisplay
  case alreadyCapturing
  case meetingApplicationUnavailable

  var errorDescription: String? {
    switch self {
    case .noDisplay: return "No display is available for system-audio capture."
    case .alreadyCapturing: return "A meeting capture is already active."
    case .meetingApplicationUnavailable:
      return "The detected meeting application is no longer available for audio capture."
    }
  }
}

final class MeetingCaptureService: NSObject {
  private let systemQueue = DispatchQueue(
    label: "com.hermeswhisper.meeting.system-audio",
    qos: .userInitiated
  )
  private let microphoneQueue = DispatchQueue(
    label: "com.hermeswhisper.meeting.microphone",
    qos: .userInitiated
  )
  private let systemConverter = AudioConverter()
  private let microphoneConverter = AudioConverter()
  private let systemFramer = MeetingAudioChunkFramer(source: .systemAudio)
  private let microphoneFramer = MeetingAudioChunkFramer(source: .microphone)
  private let systemTap = HWSystemAudioTapCapture()
  private let originLock = NSLock()
  private let fatalErrorLock = NSLock()

  private var stream: SCStream?
  private var systemWriter: MeetingAudioSegmentWriter?
  private var microphoneWriter: MeetingAudioSegmentWriter?
  private var originPTS: TimeInterval?
  private var systemTapPendingSamples: [Float] = []
  private var systemTapSampleRate: Double?
  private var systemTapNextStartTime: TimeInterval?
  private var isSystemTapCapturing = false
  private var hasReportedFatalError = false
  private var onChunk: ((MeetingAudioChunk) -> Void)?
  private var onError: ((Error) -> Void)?

  var isCapturing: Bool { stream != nil || isSystemTapCapturing }

  func start(
    directory: URL,
    includedApplicationScope: MeetingApplicationScope? = nil,
    onChunk: @escaping (MeetingAudioChunk) -> Void,
    onError: @escaping (Error) -> Void
  ) async throws {
    guard stream == nil else { throw MeetingCaptureError.alreadyCapturing }

    let content = try await SCShareableContent.current
    let mainID = CGMainDisplayID()
    guard let display = content.displays.first(where: { $0.displayID == mainID })
      ?? content.displays.first else {
      throw MeetingCaptureError.noDisplay
    }

    let filter: SCContentFilter
    let systemAudioProcessIDs: [NSNumber]
    if let includedApplicationScope {
      let includedApplications = content.applications.filter {
        includedApplicationScope.matches(
          bundleID: $0.bundleIdentifier,
          executablePath: MeetingDetector.executablePath(for: $0.processID)
        )
      }
      guard !includedApplications.isEmpty else {
        throw MeetingCaptureError.meetingApplicationUnavailable
      }
      filter = SCContentFilter(
        display: display,
        including: includedApplications,
        exceptingWindows: []
      )
      systemAudioProcessIDs = includedApplications.map { NSNumber(value: $0.processID) }
    } else {
      let ownBundleID = Bundle.main.bundleIdentifier
      let excludedApplications = content.applications.filter {
        $0.bundleIdentifier == ownBundleID
      }
      filter = SCContentFilter(
        display: display,
        excludingApplications: excludedApplications,
        exceptingWindows: []
      )
      systemAudioProcessIDs = []
    }
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 1
    configuration.capturesAudio = false
    configuration.captureMicrophone = true
    if case .deviceUID(let uid) = AudioInputSelection.load() {
      configuration.microphoneCaptureDeviceID = uid
    }

    self.onChunk = onChunk
    self.onError = onError
    self.originPTS = nil
    systemTapPendingSamples.removeAll(keepingCapacity: true)
    systemTapSampleRate = nil
    systemTapNextStartTime = nil
    systemFramer.reset()
    microphoneFramer.reset()
    resetFatalErrorState()
    self.systemWriter = MeetingAudioSegmentWriter(
      directory: directory,
      source: .systemAudio
    )
    self.microphoneWriter = MeetingAudioSegmentWriter(
      directory: directory,
      source: .microphone
    )

    systemTap.samplesHandler = { [weak self] data, sampleRate, hostTime in
      self?.handleSystemTapData(data, sampleRate: sampleRate, hostTime: hostTime)
    }

    do {
      try systemTap.start(withProcessIDs: systemAudioProcessIDs)
      isSystemTapCapturing = true
      let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
      try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
      self.stream = stream
      try await stream.startCapture()
      AppLog.dictation.log(
        "MeetingCapture: Core Audio system tap and microphone capture started"
      )
    } catch {
      if let stream {
        try? stream.removeStreamOutput(self, type: .microphone)
      }
      self.stream = nil
      systemTap.stop()
      systemTap.samplesHandler = nil
      isSystemTapCapturing = false
      self.systemWriter = nil
      self.microphoneWriter = nil
      throw error
    }
  }

  func start(
    directory: URL,
    includedApplicationFamily: String?,
    onChunk: @escaping (MeetingAudioChunk) -> Void,
    onError: @escaping (Error) -> Void
  ) async throws {
    try await start(
      directory: directory,
      includedApplicationScope: includedApplicationFamily.map {
        MeetingApplicationScope.knownFamily($0)
      },
      onChunk: onChunk,
      onError: onError
    )
  }

  func stop() async -> [String] {
    let stream = self.stream
    guard stream != nil || isSystemTapCapturing else { return [] }
    self.stream = nil
    if let stream {
      try? await stream.stopCapture()
      try? stream.removeStreamOutput(self, type: .microphone)
    }
    systemTap.stop()
    systemTap.samplesHandler = nil
    isSystemTapCapturing = false

    systemQueue.sync {
      flushSystemTapSamples()
      systemFramer.finish().forEach { onChunk?($0) }
      systemWriter?.finish()
    }
    microphoneQueue.sync {
      microphoneFramer.finish().forEach { onChunk?($0) }
      microphoneWriter?.finish()
    }
    let files = (systemWriter?.filenames ?? []) + (microphoneWriter?.filenames ?? [])
    systemWriter = nil
    microphoneWriter = nil
    onChunk = nil
    onError = nil
    AppLog.dictation.log("MeetingCapture: stopped with \(files.count) durable audio segments")
    return files.sorted()
  }

  private func relativeTime(for sampleBuffer: CMSampleBuffer) -> TimeInterval {
    let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    return relativeTime(forAbsoluteTime: pts)
  }

  private func relativeTime(forAbsoluteTime absoluteTime: TimeInterval) -> TimeInterval {
    originLock.lock()
    defer { originLock.unlock() }
    if originPTS == nil || !originPTS!.isFinite || !absoluteTime.isFinite {
      originPTS = absoluteTime
    }
    return max(0, absoluteTime - (originPTS ?? absoluteTime))
  }

  private func handleSystemTapData(
    _ data: Data,
    sampleRate: Double,
    hostTime: TimeInterval
  ) {
    guard sampleRate > 0, !data.isEmpty else { return }
    let samples = data.withUnsafeBytes { bytes -> [Float] in
      Array(bytes.bindMemory(to: Float.self))
    }
    guard !samples.isEmpty else { return }

    if let currentRate = systemTapSampleRate,
       abs(currentRate - sampleRate) > 0.5 {
      flushSystemTapSamples()
    }
    if systemTapSampleRate == nil {
      systemTapSampleRate = sampleRate
    }
    if systemTapNextStartTime == nil {
      systemTapNextStartTime = relativeTime(forAbsoluteTime: hostTime)
    }
    systemTapPendingSamples.append(contentsOf: samples)
    drainSystemTapSamples(includePartialFrame: false)
  }

  private func flushSystemTapSamples() {
    drainSystemTapSamples(includePartialFrame: true)
    systemTapPendingSamples.removeAll(keepingCapacity: true)
    systemTapSampleRate = nil
    systemTapNextStartTime = nil
  }

  private func drainSystemTapSamples(includePartialFrame: Bool) {
    guard let sampleRate = systemTapSampleRate,
          let frameStartTime = systemTapNextStartTime else { return }
    let nativeFrameCount = max(1, Int((sampleRate * 0.1).rounded()))
    var consumedSampleCount = 0
    var nextStartTime = frameStartTime

    while systemTapPendingSamples.count - consumedSampleCount >= nativeFrameCount
      || (includePartialFrame && systemTapPendingSamples.count > consumedSampleCount) {
      let available = systemTapPendingSamples.count - consumedSampleCount
      let sampleCount = min(nativeFrameCount, available)
      let endIndex = consumedSampleCount + sampleCount
      let nativeSamples = Array(systemTapPendingSamples[consumedSampleCount..<endIndex])
      do {
        let samples = try systemConverter.resample(nativeSamples, from: sampleRate)
        if !samples.isEmpty {
          try systemWriter?.append(samples: samples)
          systemFramer.append(samples: samples, startTime: nextStartTime).forEach {
            onChunk?($0)
          }
        }
      } catch {
        AppLog.dictation.error(
          "MeetingCapture: system tap sample failed: \(error.localizedDescription)"
        )
        reportFatalError(error)
        return
      }
      consumedSampleCount = endIndex
      nextStartTime += Double(sampleCount) / sampleRate
    }

    if consumedSampleCount == systemTapPendingSamples.count {
      systemTapPendingSamples.removeAll(keepingCapacity: true)
    } else if consumedSampleCount > 0 {
      systemTapPendingSamples = Array(systemTapPendingSamples.dropFirst(consumedSampleCount))
    }
    systemTapNextStartTime = nextStartTime
  }

  private func handle(_ sampleBuffer: CMSampleBuffer, source: MeetingAudioSource) {
    guard CMSampleBufferIsValid(sampleBuffer),
          CMSampleBufferDataIsReady(sampleBuffer) else { return }
    do {
      let converter = source == .microphone ? microphoneConverter : systemConverter
      let samples = try converter.resampleSampleBuffer(sampleBuffer)
      guard !samples.isEmpty else { return }
      let writer = source == .microphone ? microphoneWriter : systemWriter
      try writer?.append(samples: samples)
      let startTime = relativeTime(for: sampleBuffer)
      let framer = source == .microphone ? microphoneFramer : systemFramer
      framer.append(samples: samples, startTime: startTime).forEach { onChunk?($0) }
    } catch {
      AppLog.dictation.error(
        "MeetingCapture: \(source.rawValue) sample failed: \(error.localizedDescription)"
      )
      reportFatalError(error)
    }
  }

  private func reportFatalError(_ error: Error) {
    fatalErrorLock.lock()
    let shouldReport = !hasReportedFatalError
    hasReportedFatalError = true
    fatalErrorLock.unlock()
    if shouldReport {
      onError?(error)
    }
  }

  private func resetFatalErrorState() {
    fatalErrorLock.lock()
    hasReportedFatalError = false
    fatalErrorLock.unlock()
  }
}

extension MeetingCaptureService: SCStreamOutput {
  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    switch outputType {
    case .microphone:
      handle(sampleBuffer, source: .microphone)
    default:
      break
    }
  }
}

extension MeetingCaptureService: SCStreamDelegate {
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    AppLog.dictation.error("MeetingCapture: stream stopped: \(error.localizedDescription)")
    reportFatalError(error)
  }
}
