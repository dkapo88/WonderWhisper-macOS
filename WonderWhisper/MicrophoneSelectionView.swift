import SwiftUI
import AVFoundation

struct MicrophoneSelectionView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var availableDevices: [AudioDeviceInfo] = []
  @State private var systemDefaultUID: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        GroupBox("Microphone input") {
          VStack(alignment: .leading, spacing: 16) {
            Text("Select which microphone WonderWhisper uses for recording. The system default option automatically switches based on your connected devices.")
              .font(.caption)
              .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
              systemDefaultButton
              
              Divider()
                .padding(.vertical, 4)
              
              if !availableDevices.isEmpty {
                Text("Available microphones (\(availableDevices.count))")
                  .font(.caption)
                  .foregroundColor(.secondary)
                
                ForEach(availableDevices, id: \.uid) { device in
                  deviceButton(for: device)
                }
              } else {
                HStack {
                  ProgressView()
                  Text("Loading devices...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
              }
            }
            
            HStack(spacing: 8) {
              Button {
                Task {
                  await refreshDevicesAsync()
                }
              } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
              }
              .buttonStyle(.borderless)
              
              Spacer()
              
              if systemDefaultUID != nil {
                Text("Current system default: \(systemDefaultDeviceName)")
                  .font(.caption2)
                  .foregroundColor(.secondary)
              }
            }
            .padding(.top, 8)
          }
          .padding(.top, 4)
        }
        
        Spacer(minLength: 0)
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task {
      loadCurrentSelection()
      await refreshDevicesAsync()
    }
  }
  
  private var systemDefaultButton: some View {
    Button {
      selectSystemDefault()
    } label: {
      HStack(spacing: 12) {
        Image(systemName: isSystemDefaultSelected ? "checkmark.circle.fill" : "circle")
          .foregroundColor(isSystemDefaultSelected ? .accentColor : .secondary)
          .font(.title3)
        
        VStack(alignment: .leading, spacing: 4) {
          Text("System Default")
            .font(.callout.weight(.semibold))
          
          Text("Automatically switches between devices")
            .font(.caption)
            .foregroundColor(.secondary)
        }
        
        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isSystemDefaultSelected ? Color.accentColor.opacity(0.1) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(isSystemDefaultSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1.5)
    )
  }
  
  private func deviceButton(for device: AudioDeviceInfo) -> some View {
    Button {
      selectDevice(device)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: isDeviceSelected(device) ? "checkmark.circle.fill" : "circle")
          .foregroundColor(isDeviceSelected(device) ? .accentColor : .secondary)
          .font(.title3)
        
        VStack(alignment: .leading, spacing: 4) {
          Text(device.name)
            .font(.callout.weight(.semibold))
          
          if let uid = systemDefaultUID, uid == device.uid {
            Text("Currently active as system default")
              .font(.caption)
              .foregroundColor(.green)
          }
        }
        
        Spacer()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isDeviceSelected(device) ? Color.accentColor.opacity(0.1) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(isDeviceSelected(device) ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1.5)
    )
  }
  
  private var isSystemDefaultSelected: Bool {
    if case .systemDefault = vm.audioInputSelection {
      return true
    }
    return false
  }
  
  private func isDeviceSelected(_ device: AudioDeviceInfo) -> Bool {
    if case .deviceUID(let uid) = vm.audioInputSelection {
      return uid == device.uid
    }
    return false
  }
  
  private var systemDefaultDeviceName: String {
    guard let uid = systemDefaultUID else { return "Unknown" }
    return availableDevices.first(where: { $0.uid == uid })?.name ?? "Unknown"
  }
  
  private func loadCurrentSelection() {
    vm.audioInputSelection = AudioInputSelection.load()
    Task {
      let uid = await getSystemDefaultUID()
      await MainActor.run {
        systemDefaultUID = uid
      }
    }
  }
  

  
  private func refreshDevicesAsync() async {
    let devices = await getAvailableDevices()
    let uid = await getSystemDefaultUID()
    print("🎤 Found \(devices.count) audio devices")
    for device in devices {
      print("  - \(device.name) (\(device.uid))")
    }
    print("  System default: \(uid ?? "none")")
    await MainActor.run {
      availableDevices = devices
      systemDefaultUID = uid
    }
  }
  
  private func getAvailableDevices() async -> [AudioDeviceInfo] {
    await Task.detached {
      AudioDeviceManager.availableInputDevices()
    }.value
  }
  
  private func getSystemDefaultUID() async -> String? {
    await Task.detached {
      AudioDeviceManager.currentDefaultInputUID()
    }.value
  }
  
  private func selectSystemDefault() {
    print("🎤 Selected: System Default")
    vm.audioInputSelection = .systemDefault
    Task {
      let uid = await getSystemDefaultUID()
      await MainActor.run {
        systemDefaultUID = uid
      }
    }
  }
  
  private func selectDevice(_ device: AudioDeviceInfo) {
    print("🎤 Selected device: \(device.name) (\(device.uid))")
    vm.audioInputSelection = .deviceUID(device.uid)
  }
}

#Preview {
  MicrophoneSelectionView(vm: DictationViewModel())
}
