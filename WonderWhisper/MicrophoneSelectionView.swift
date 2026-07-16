import AVFoundation
import SwiftUI

struct MicrophoneSelectionView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var availableDevices: [AudioDeviceInfo] = []
  @State private var priorityDevices: [AudioDeviceInfo] = []
  @State private var systemDefaultUID: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        GroupBox("Microphone input") {
          VStack(alignment: .leading, spacing: 16) {
            systemDefaultButton

            Divider()

            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text("Preferred order")
                  .font(.headline)
                Text("WonderWhisper uses the first available microphone, then the system default.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button {
                Task { await refreshDevices() }
              } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
              }
              .buttonStyle(.borderless)
            }

            if priorityDevices.isEmpty {
              ContentUnavailableView(
                "No microphones found",
                systemImage: "mic.slash",
                description: Text("Connect a microphone and refresh this list.")
              )
              .frame(maxWidth: .infinity)
            } else {
              VStack(spacing: 8) {
                ForEach(Array(priorityDevices.enumerated()), id: \.element.uid) { index, device in
                  priorityRow(device, at: index)
                }
              }
            }

            if let activeDeviceName {
              Label("Will use: \(activeDeviceName)", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.top, 4)
        }

        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task {
      vm.audioInputSelection = AudioInputSelection.load()
      await refreshDevices()
    }
  }

  private var systemDefaultButton: some View {
    Button {
      vm.audioInputSelection = .systemDefault
    } label: {
      HStack(spacing: 12) {
        Image(systemName: isSystemDefaultSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSystemDefaultSelected ? Color.accentColor : Color.secondary)
          .font(.title3)

        VStack(alignment: .leading, spacing: 4) {
          Text("System Default")
            .font(.callout.weight(.semibold))
          Text(systemDefaultDeviceName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(12)
    .background(selectionBackground(isSelected: isSystemDefaultSelected))
    .overlay(selectionBorder(isSelected: isSystemDefaultSelected))
  }

  private func priorityRow(_ device: AudioDeviceInfo, at index: Int) -> some View {
    let isAvailable = availableUIDs.contains(device.uid)
    let isPreferred = !isSystemDefaultSelected && index == 0
    let isActive = !isSystemDefaultSelected && resolvedUID == device.uid

    return HStack(spacing: 10) {
      Button {
        selectDevice(device)
      } label: {
        HStack(spacing: 10) {
          Text("\(index + 1)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20)

          Image(systemName: isPreferred ? "checkmark.circle.fill" : "mic")
            .foregroundStyle(isPreferred ? Color.accentColor : Color.secondary)
            .frame(width: 20)

          VStack(alignment: .leading, spacing: 3) {
            Text(device.name)
              .font(.callout.weight(.medium))
            Text(deviceStatus(isAvailable: isAvailable, isActive: isActive))
              .font(.caption)
              .foregroundStyle(deviceStatusColor(isAvailable: isAvailable, isActive: isActive))
          }

          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Button {
        moveDevice(at: index, by: -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .disabled(index == 0)
      .help("Move up")

      Button {
        moveDevice(at: index, by: 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .disabled(index == priorityDevices.count - 1)
      .help("Move down")

      if !isAvailable {
        Button(role: .destructive) {
          removeDevice(device)
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Forget unavailable microphone")
      }
    }
    .padding(10)
    .background(selectionBackground(isSelected: isPreferred))
    .overlay(selectionBorder(isSelected: isPreferred))
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

  private var systemDefaultDeviceName: String {
    guard let systemDefaultUID else { return "Automatically follows macOS" }
    let name = availableDevices.first(where: { $0.uid == systemDefaultUID })?.name
      ?? "Automatically follows macOS"
    return "Currently \(name)"
  }

  private func deviceStatus(isAvailable: Bool, isActive: Bool) -> String {
    if isActive { return "In use" }
    return isAvailable ? "Available" : "Unavailable"
  }

  private func deviceStatusColor(isAvailable: Bool, isActive: Bool) -> Color {
    if isActive { return .green }
    return isAvailable ? .secondary : .orange
  }

  private func selectionBackground(isSelected: Bool) -> some ShapeStyle {
    isSelected ? Color.accentColor.opacity(0.1) : Color.clear
  }

  private func selectionBorder(isSelected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 8)
      .stroke(
        isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
        lineWidth: isSelected ? 1.5 : 1
      )
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

#Preview {
  MicrophoneSelectionView(vm: DictationViewModel())
}
