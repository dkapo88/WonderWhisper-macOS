import Foundation
import CoreAudio
import AppKit

final class SystemAudioController {
  static let shared = SystemAudioController()
  
  private var volumeBeforeMute: Float32?
  private var wasMutedBeforeRecording: Bool = false
  private var shouldRestoreAfterMute = false
  private var mutedDeviceID: AudioDeviceID?
  private let meetingStateLock = NSLock()
  private var meetingCaptureActive = false
  
  private init() {}

  func setMeetingCaptureActive(_ active: Bool) {
    meetingStateLock.lock()
    meetingCaptureActive = active
    meetingStateLock.unlock()
  }

  private var isMeetingCaptureActive: Bool {
    meetingStateLock.lock()
    defer { meetingStateLock.unlock() }
    return meetingCaptureActive
  }
  
  @discardableResult
  func muteSystemAudioAndWait(settleMs: useconds_t = 100_000) -> Bool {
    if shouldRestoreAfterMute {
      unmuteSystemAudioAndWait()
      guard !shouldRestoreAfterMute else { return false }
    }
    shouldRestoreAfterMute = false
    mutedDeviceID = nil
    guard !isMeetingCaptureActive else {
      AppLog.hotkeys.log(
        "Auto-mute suppressed while meeting capture is recording system audio"
      )
      return false
    }
    guard let deviceID = getDefaultOutputDevice() else {
      AppLog.hotkeys.error("Failed to get default output device for muting")
      return false
    }
    
    guard isAutoMuteSafe(deviceID: deviceID) else {
      AppLog.hotkeys.log("Auto-mute suppressed for current output device (BT/aggregate/linked IO)")
      return false
    }
    
    volumeBeforeMute = getVolume(for: deviceID)
    wasMutedBeforeRecording = isMuted(for: deviceID)
    
    let ok = setMuted(true, for: deviceID)
    if ok {
      shouldRestoreAfterMute = true
      mutedDeviceID = deviceID
      waitForMute(true, deviceID: deviceID)
      if settleMs > 0 {
        usleep(settleMs)
      }
    }
    AppLog.hotkeys.log("System audio muted. Prev vol: \(self.volumeBeforeMute ?? 0.0), wasMuted: \(self.wasMutedBeforeRecording), ok: \(ok)")
    return ok
  }
  
  func unmuteSystemAudioAndWait() {
    guard shouldRestoreAfterMute, let deviceID = mutedDeviceID else {
      AppLog.hotkeys.log("System audio restore skipped because auto-mute was not applied")
      return
    }

    var restorationComplete = false
    if !wasMutedBeforeRecording {
      let ok = setMuted(false, for: deviceID)
      if ok {
        waitForMute(false, deviceID: deviceID)
        restorationComplete = true
      }
      AppLog.hotkeys.log("System audio unmuted ok: \(ok)")
    } else {
      AppLog.hotkeys.log("System audio was already muted before recording, keeping it muted")
      restorationComplete = true
    }

    if restorationComplete {
      shouldRestoreAfterMute = false
      mutedDeviceID = nil
      volumeBeforeMute = nil
    } else {
      AppLog.hotkeys.error("System audio restore failed; retaining the original device for retry")
    }
  }
  
  private func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var deviceIDSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &deviceIDSize,
      &deviceID
    )
    
    guard status == noErr else { return nil }
    return deviceID
  }
  
  private func getVolume(for deviceID: AudioDeviceID) -> Float32? {
    var volume = Float32(0)
    var volumeSize = UInt32(MemoryLayout<Float32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyVolumeScalar,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &volumeSize,
      &volume
    )
    
    guard status == noErr else { return nil }
    return volume
  }
  
  private func isMuted(for deviceID: AudioDeviceID) -> Bool {
    var mute = UInt32(0)
    var muteSize = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &muteSize,
      &mute
    )
    
    guard status == noErr else { return false }
    return mute != 0
  }
  
  @discardableResult
  private func setMuted(_ muted: Bool, for deviceID: AudioDeviceID) -> Bool {
    var mute = UInt32(muted ? 1 : 0)
    let muteSize = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    
    let status = AudioObjectSetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      muteSize,
      &mute
    )
    
    if status != noErr {
      AppLog.hotkeys.error("Failed to set mute state: \(status)")
    }
    return status == noErr
  }
  
  private func waitForMute(_ desired: Bool, deviceID: AudioDeviceID, timeoutMs: Int = 150) {
    let start = Date()
    while Date().timeIntervalSince(start) * 1000 < Double(timeoutMs) {
      if isMuted(for: deviceID) == desired {
        return
      }
      usleep(20_000)
    }
  }
  
  private func isAutoMuteSafe(deviceID: AudioDeviceID) -> Bool {
    var transportType = UInt32(0)
    var transportTypeSize = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyTransportType,
      mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain
    )
    
    let status = AudioObjectGetPropertyData(
      deviceID,
      &address,
      0,
      nil,
      &transportTypeSize,
      &transportType
    )
    
    if status == noErr && transportType == kAudioDeviceTransportTypeBluetooth {
      return false
    }
    
    return true
  }
}
