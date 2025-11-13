import Foundation
import CoreAudio
import AppKit

final class SystemAudioController {
  static let shared = SystemAudioController()
  
  private var volumeBeforeMute: Float32?
  private var wasMutedBeforeRecording: Bool = false
  
  private init() {}
  
  func muteSystemAudio() {
    guard let deviceID = getDefaultOutputDevice() else {
      AppLog.hotkeys.error("Failed to get default output device for muting")
      return
    }
    
    volumeBeforeMute = getVolume(for: deviceID)
    wasMutedBeforeRecording = isMuted(for: deviceID)
    
    setMuted(true, for: deviceID)
    AppLog.hotkeys.log("System audio muted. Previous volume: \(self.volumeBeforeMute ?? 0.0), was muted: \(self.wasMutedBeforeRecording)")
  }
  
  func unmuteSystemAudio() {
    guard let deviceID = getDefaultOutputDevice() else {
      AppLog.hotkeys.error("Failed to get default output device for unmuting")
      return
    }
    
    if !wasMutedBeforeRecording {
      setMuted(false, for: deviceID)
      AppLog.hotkeys.log("System audio unmuted")
    } else {
      AppLog.hotkeys.log("System audio was already muted before recording, keeping it muted")
    }
    
    volumeBeforeMute = nil
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
  
  private func setMuted(_ muted: Bool, for deviceID: AudioDeviceID) {
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
  }
}
