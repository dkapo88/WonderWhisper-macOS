import SwiftUI

/// Settings → Audio: microphone priority, recording behavior, and feedback sounds.
struct AudioSettingsPane: View {
  @ObservedObject var vm: DictationViewModel
  @State private var availableDevices: [AudioDeviceInfo] = []
  @State private var priorityDevices: [AudioDeviceInfo] = []
  @State private var systemDefaultUID: String?

  private enum InputMode: Hashable {
    case systemDefault
    case preferredOrder
  }

  var body: some View {
    SettingsPage {
      inputSection
      if !isSystemDefaultSelected {
        priorityListSection
      }

      Section {
        Toggle(isOn: $vm.autoMuteEnabled) {
          Text("Mute system audio while recording")
          Text("Stops music and calls from bleeding into the transcription.")
        }
        LabeledContent {
          Slider(value: $vm.chimeVolume, in: 0...1) {
            Text("Chime volume")
          } minimumValueLabel: {
            Image(systemName: "speaker")
          } maximumValueLabel: {
            Image(systemName: "speaker.wave.3")
          }
          .labelsHidden()
          .frame(width: 220)
          .accessibilityLabel("Chime volume")
        } label: {
          Text("Chime volume")
          Text("Start and stop chime, relative to system volume.")
        }
      } header: {
        Text("Recording")
      }
    }
    .task {
      vm.audioInputSelection = AudioInputSelection.load()
      await refreshDevices()
    }
  }

  // MARK: - Input

  private var inputSection: some View {
    Section {
      Picker(selection: inputModeBinding) {
        Text("System default").tag(InputMode.systemDefault)
        Text("Preferred order").tag(InputMode.preferredOrder)
      } label: {
        Text("Microphone")
        Text(isSystemDefaultSelected
          ? "Follows the input chosen in macOS Sound settings."
          : "Uses the first available microphone in your list, then the system default.")
      }
      .pickerStyle(.segmented)

      LabeledContent("Currently using") {
        if let activeDeviceName {
          Text(activeDeviceName)
        } else {
          Text("No microphone found")
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Input")
    }
  }

  private var priorityListSection: some View {
    Section {
      if priorityDevices.isEmpty {
        Text("No microphones found. Connect one and refresh.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(priorityDevices.enumerated()), id: \.element.uid) { index, device in
          priorityRow(device, at: index)
        }
      }
    } header: {
      HStack {
        Text("Preferred order")
        Spacer()
        Button {
          Task { await refreshDevices() }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel("Refresh microphones")
      }
    } footer: {
      Text("Click a microphone to move it to the top. Unavailable microphones stay in the list "
        + "until you forget them.")
        .settingsFootnote()
    }
  }

  private func priorityRow(_ device: AudioDeviceInfo, at index: Int) -> some View {
    let isAvailable = availableUIDs.contains(device.uid)
    let isActive = resolvedUID == device.uid

    return LabeledContent {
      HStack(spacing: DesignTokens.Spacing.xSmall) {
        deviceBadge(isAvailable: isAvailable, isActive: isActive)

        Button {
          moveDevice(at: index, by: -1)
        } label: {
          Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .disabled(index == 0)
        .help("Move up")
        .accessibilityLabel("Move \(device.name) up")

        Button {
          moveDevice(at: index, by: 1)
        } label: {
          Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
        .disabled(index == priorityDevices.count - 1)
        .help("Move down")
        .accessibilityLabel("Move \(device.name) down")

        if !isAvailable {
          Button("Forget", role: .destructive) {
            removeDevice(device)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Forget \(device.name)")
        }
      }
    } label: {
      Button {
        selectDevice(device)
      } label: {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
          Text("\(index + 1).")
            .monospacedDigit()
            .foregroundStyle(.secondary)
          Text(device.name)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(device.name), priority \(index + 1)")
      .accessibilityHint("Moves this microphone to the top of the list")
    }
  }

  @ViewBuilder
  private func deviceBadge(isAvailable: Bool, isActive: Bool) -> some View {
    if isActive {
      StatusBadge(.ok, "In use")
    } else if isAvailable {
      StatusBadge(.neutral, "Available")
    } else {
      StatusBadge(.warning, "Unavailable")
    }
  }

  // MARK: - State

  private var inputModeBinding: Binding<InputMode> {
    Binding(
      get: { isSystemDefaultSelected ? .systemDefault : .preferredOrder },
      set: { mode in
        switch mode {
        case .systemDefault:
          vm.audioInputSelection = .systemDefault
        case .preferredOrder:
          let first = priorityDevices.first(where: { availableUIDs.contains($0.uid) })
            ?? priorityDevices.first
          if let first {
            vm.audioInputSelection = .deviceUID(first.uid)
          }
        }
      }
    )
  }

  private var availableUIDs: Set<String> {
    Set(availableDevices.map(\.uid))
  }

  private var isSystemDefaultSelected: Bool {
    vm.audioInputSelection == .systemDefault
  }

  private var resolvedUID: String? {
    if isSystemDefaultSelected { return systemDefaultUID }
    return AudioDeviceManager.preferredInputUID(
      priorityUIDs: priorityDevices.map(\.uid),
      availableUIDs: availableUIDs,
      systemDefaultUID: systemDefaultUID
    )
  }

  private var activeDeviceName: String? {
    guard let resolvedUID else { return nil }
    return availableDevices.first(where: { $0.uid == resolvedUID })?.name
      ?? priorityDevices.first(where: { $0.uid == resolvedUID })?.name
  }

  private func refreshDevices() async {
    async let devices = Task.detached { AudioDeviceManager.availableInputDevices() }.value
    async let defaultUID = Task.detached { AudioDeviceManager.currentDefaultInputUID() }.value
    let (available, systemUID) = await (devices, defaultUID)
    let merged = AudioDeviceManager.mergedInputPriorities(
      stored: AudioDeviceManager.inputPriorities(),
      available: available,
      selection: vm.audioInputSelection
    )
    availableDevices = available
    systemDefaultUID = systemUID
    priorityDevices = merged
    AudioDeviceManager.saveInputPriorities(merged)
  }

  private func selectDevice(_ device: AudioDeviceInfo) {
    priorityDevices = AudioDeviceManager.promoted(device, in: priorityDevices)
    AudioDeviceManager.saveInputPriorities(priorityDevices)
    vm.audioInputSelection = .deviceUID(device.uid)
  }

  private func moveDevice(at index: Int, by offset: Int) {
    let destination = index + offset
    guard priorityDevices.indices.contains(index),
          priorityDevices.indices.contains(destination) else { return }
    priorityDevices.swapAt(index, destination)
    AudioDeviceManager.saveInputPriorities(priorityDevices)
    if !isSystemDefaultSelected, let first = priorityDevices.first {
      vm.audioInputSelection = .deviceUID(first.uid)
    }
  }

  private func removeDevice(_ device: AudioDeviceInfo) {
    priorityDevices.removeAll { $0.uid == device.uid }
    AudioDeviceManager.saveInputPriorities(priorityDevices)
    guard !isSystemDefaultSelected else { return }
    vm.audioInputSelection = priorityDevices.first.map { .deviceUID($0.uid) } ?? .systemDefault
  }
}
