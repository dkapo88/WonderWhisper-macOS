import Foundation
import AVFoundation
import CoreAudio

enum AudioInputSelection: Equatable {
    case systemDefault
    case deviceUID(String)

    static func load() -> AudioInputSelection {
        if let uid = UserDefaults.standard.string(forKey: "audio.input.uid"), !uid.isEmpty {
            return .deviceUID(uid)
        }
        return .systemDefault
    }

    func persist() {
        switch self {
        case .systemDefault:
            UserDefaults.standard.removeObject(forKey: "audio.input.uid")
        case .deviceUID(let uid):
            UserDefaults.standard.set(uid, forKey: "audio.input.uid")
        }
    }
}

struct AudioDeviceInfo: Codable, Hashable, Identifiable {
    let uid: String
    let name: String

    var id: String { uid }
}

enum AudioDeviceManager {
    private static let inputPrioritiesKey = "audio.input.priorities"

    static func inputPriorities(defaults: UserDefaults = .standard) -> [AudioDeviceInfo] {
        if let data = defaults.data(forKey: inputPrioritiesKey),
           let devices = try? JSONDecoder().decode([AudioDeviceInfo].self, from: data) {
            return devices
        }
        guard let uid = defaults.string(forKey: "audio.input.uid"), !uid.isEmpty else {
            return []
        }
        return [AudioDeviceInfo(uid: uid, name: uid)]
    }

    static func saveInputPriorities(
        _ devices: [AudioDeviceInfo],
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: inputPrioritiesKey)
    }

    static func mergedInputPriorities(
        stored: [AudioDeviceInfo],
        available: [AudioDeviceInfo],
        selection: AudioInputSelection
    ) -> [AudioDeviceInfo] {
        let availableByUID = available.reduce(into: [String: AudioDeviceInfo]()) {
            $0[$1.uid] = $1
        }
        let storedByUID = stored.reduce(into: [String: AudioDeviceInfo]()) {
            $0[$1.uid] = $1
        }
        let preferredUID: String? = if case .deviceUID(let uid) = selection { uid } else { nil }
        var seen: Set<String> = []
        var result: [AudioDeviceInfo] = []

        for uid in [preferredUID].compactMap({ $0 }) + stored.map(\.uid) + available.map(\.uid) {
            guard seen.insert(uid).inserted else { continue }
            result.append(
                availableByUID[uid]
                    ?? storedByUID[uid]
                    ?? AudioDeviceInfo(uid: uid, name: "Previously selected microphone")
            )
        }
        return result
    }

    static func promoted(
        _ device: AudioDeviceInfo,
        in priorities: [AudioDeviceInfo]
    ) -> [AudioDeviceInfo] {
        [device] + priorities.filter { $0.uid != device.uid }
    }

    static func preferredInputUID(
        priorityUIDs: [String],
        availableUIDs: Set<String>,
        systemDefaultUID: String?
    ) -> String? {
        priorityUIDs.first(where: availableUIDs.contains) ?? systemDefaultUID
    }

    static func resolvedInputUID(for selection: AudioInputSelection) -> String? {
        guard case .deviceUID(let selectedUID) = selection else { return nil }
        let available = availableInputDevices()
        let priorityUIDs = [selectedUID] + inputPriorities().map(\.uid).filter {
            $0 != selectedUID
        }
        return preferredInputUID(
            priorityUIDs: priorityUIDs,
            availableUIDs: Set(available.map(\.uid)),
            systemDefaultUID: currentDefaultInputUID()
        )
    }

    static func availableInputDevices() -> [AudioDeviceInfo] {
        // Enumerate HAL audio devices to avoid CMIO/camera dependency and entitlement noise
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = Array(repeating: AudioObjectID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        var result: [AudioDeviceInfo] = []
        for id in ids {
            if inputChannelCount(deviceID: id) > 0, let uid = deviceUID(from: id), let name = deviceName(from: id) {
                result.append(AudioDeviceInfo(uid: uid, name: name))
            }
        }
        return result
    }

    static func currentDefaultInputUID() -> String? {
        var deviceID = AudioObjectID(0)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceUID(from: deviceID)
    }

    // MARK: - Input Volume (Gain)
    /// Volume property addresses to try in order: master element first, then channel 1.
    /// Only addresses the device actually exposes are returned, preserving the
    /// "try master element else fall back to channel 1" semantics shared by get/set.
    private static func volumePropertyAddresses(for dev: AudioObjectID) -> [AudioObjectPropertyAddress] {
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1]
        var addresses: [AudioObjectPropertyAddress] = []
        for element in elements {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeInput, mElement: element)
            if AudioObjectHasProperty(dev, &addr) {
                addresses.append(addr)
            }
        }
        return addresses
    }

    static func inputVolume(uid: String) -> Float? {
        guard let dev = deviceID(forUID: uid) else { return nil }
        for var addr in volumePropertyAddresses(for: dev) {
            var vol: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            let status = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol)
            if status == noErr { return vol }
        }
        return nil
    }

    @discardableResult
    static func setInputVolume(uid: String, volume: Float) -> Bool {
        guard let dev = deviceID(forUID: uid) else { return false }
        var vol = max(0, min(1, volume))
        for var addr in volumePropertyAddresses(for: dev) {
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol) == noErr { return true }
        }
        return false
    }

    @discardableResult
    static func raiseInputVolumeIfNeeded(for selection: AudioInputSelection) -> Bool {
        let effectiveUID: String?
        switch selection {
        case .systemDefault:
            effectiveUID = currentDefaultInputUID()
        case .deviceUID:
            effectiveUID = resolvedInputUID(for: selection)
        }
        guard let uid = effectiveUID else { return false }
        if let current = inputVolume(uid: uid) {
            if current < 0.99 {
                return setInputVolume(uid: uid, volume: 1.0)
            }
            return true
        } else {
            // Some devices don't expose software gain; nothing to do
            return false
        }
    }
    
    static func deviceUID(from deviceID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        if status != noErr { return nil }
        // Retrieve as CFString? via typed pointer to avoid raw pointer diagnostics
        var cfString: CFString? = nil
        status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            return AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = cfString else { return nil }
        return cf as String
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = Array(repeating: AudioObjectID(0), count: count)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)
        guard status == noErr else { return nil }
        for id in devices {
            if let dUID = deviceUID(from: id), dUID == uid { return id }
        }
        return nil
    }

    // MARK: - Helpers
    private static func deviceName(from deviceID: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cf) { ptr -> OSStatus in
            return AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let s = cf as String? else { return nil }
        return s
    }

    private static func inputChannelCount(deviceID: AudioObjectID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        // Allocate buffer list
        let ablPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size) / MemoryLayout<AudioBufferList>.size)
        defer { ablPtr.deallocate() }
        var status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ablPtr)
        guard status == noErr else { return 0 }
        // Sum channels
        var channels: UInt32 = 0
        let mBuffers = Int(ablPtr.pointee.mNumberBuffers)
        let bufPtr = UnsafeBufferPointer(start: &ablPtr.pointee.mBuffers, count: mBuffers)
        for i in 0..<mBuffers { channels += bufPtr[i].mNumberChannels }
        return channels
    }

    @discardableResult
    static func setSystemDefaultInput(toUID uid: String) -> Bool {
        guard let dev = deviceID(forUID: uid) else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var newDev = dev
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &newDev)
        return status == noErr
    }

    /// Polls for the default input device to switch to the given UID, up to a timeout in seconds.
    /// Returns true if the switch is observed; false on timeout or error.
    static func waitForDefaultInputSwitch(toUID uid: String, timeout: TimeInterval = 1.0) -> Bool {
        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while Date() < deadline {
            if currentDefaultInputUID() == uid { return true }
            // Small sleep to avoid busy loop; HAL notifications are not used here to keep things simple
            usleep(20_000) // 20ms
        }
        return currentDefaultInputUID() == uid
    }
}
