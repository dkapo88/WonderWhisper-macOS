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
  private let originLock = NSLock()
  private let fatalErrorLock = NSLock()

  private var stream: SCStream?
  private var systemWriter: MeetingAudioSegmentWriter?
  private var microphoneWriter: MeetingAudioSegmentWriter?
  private var originPTS: TimeInterval?
  private var hasReportedFatalError = false
  private var onChunk: ((MeetingAudioChunk) -> Void)?
  private var onError: ((Error) -> Void)?

  var isCapturing: Bool { stream != nil }

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
    }
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 1
    configuration.capturesAudio = true
    configuration.sampleRate = 16_000
    configuration.channelCount = 1
    configuration.excludesCurrentProcessAudio = true
    configuration.captureMicrophone = true
    if case .deviceUID(let uid) = AudioInputSelection.load() {
      configuration.microphoneCaptureDeviceID = uid
    }

    self.onChunk = onChunk
    self.onError = onError
    self.originPTS = nil
    resetFatalErrorState()
    self.systemWriter = MeetingAudioSegmentWriter(
      directory: directory,
      source: .systemAudio
    )
    self.microphoneWriter = MeetingAudioSegmentWriter(
      directory: directory,
      source: .microphone
    )

    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
    try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
    self.stream = stream

    do {
      try await stream.startCapture()
      AppLog.dictation.log("MeetingCapture: system audio and microphone capture started")
    } catch {
      try? stream.removeStreamOutput(self, type: .audio)
      try? stream.removeStreamOutput(self, type: .microphone)
      self.stream = nil
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
    guard let stream else { return [] }
    self.stream = nil
    try? await stream.stopCapture()
    try? stream.removeStreamOutput(self, type: .audio)
    try? stream.removeStreamOutput(self, type: .microphone)

    systemQueue.sync { systemWriter?.finish() }
    microphoneQueue.sync { microphoneWriter?.finish() }
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
    originLock.lock()
    defer { originLock.unlock() }
    if originPTS == nil || !originPTS!.isFinite {
      originPTS = pts
    }
    return max(0, pts - (originPTS ?? pts))
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
      onChunk?(
        MeetingAudioChunk(
          source: source,
          samples: samples,
          startTime: startTime,
          duration: Double(samples.count) / 16_000
        )
      )
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
    case .audio:
      handle(sampleBuffer, source: .systemAudio)
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
