import SwiftUI
import AppKit
import AVFoundation
import IOKit.hid

struct PermissionsView: View {
  @State private var permissions = AppPermissionStatus.current()
  @State private var isRequestingMicrophone = false

  private var requiredPermissions: [AppPermission] {
    [
      .microphone,
      .screenRecording,
      .accessibility,
      .inputMonitoring
    ]
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header

        VStack(alignment: .leading, spacing: 12) {
          ForEach(requiredPermissions) { permission in
            PermissionRow(
              permission: permission,
              isGranted: permissions.isGranted(permission),
              isRequesting: isRequestingMicrophone && permission == .microphone,
              requestAction: { request(permission) },
              settingsAction: { permission.openSettings() }
            )
          }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear(perform: refresh)
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      refresh()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Permissions")
        .font(.title2.weight(.semibold))
      Text("HermesWhisper needs these macOS permissions for recording, context capture, hotkeys, and text insertion.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func refresh() {
    permissions = AppPermissionStatus.current()
  }

  private func request(_ permission: AppPermission) {
    switch permission {
    case .microphone:
      isRequestingMicrophone = true
      AVCaptureDevice.requestAccess(for: .audio) { _ in
        Task { @MainActor in
          isRequestingMicrophone = false
          refresh()
        }
      }
    case .screenRecording:
      _ = CGRequestScreenCaptureAccess()
      refreshAfterDelay()
    case .accessibility:
      let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      let options: CFDictionary = [key: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
      refreshAfterDelay()
    case .inputMonitoring:
      _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
      refreshAfterDelay()
    }
  }

  private func refreshAfterDelay() {
    refresh()
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 700_000_000)
      refresh()
    }
  }
}

private struct PermissionRow: View {
  let permission: AppPermission
  let isGranted: Bool
  let isRequesting: Bool
  let requestAction: () -> Void
  let settingsAction: () -> Void

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .font(.title3)
            .foregroundStyle(isGranted ? .green : .orange)
            .frame(width: 24)

          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
              Text(permission.title)
                .font(.headline)

              Text(isGranted ? "Enabled" : "Needs access")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isGranted ? .green : .orange)
            }

            Text(permission.detail)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          Spacer(minLength: 12)
        }

        if !isGranted {
          HStack(spacing: 10) {
            Button(action: requestAction) {
              if isRequesting {
                ProgressView()
                  .controlSize(.small)
              } else {
                Label(permission.requestTitle, systemImage: "lock.open")
              }
            }
            .disabled(isRequesting)

            Button(action: settingsAction) {
              Label("Open Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
          }
          .padding(.leading, 36)
        }
      }
      .padding(.vertical, 4)
    }
  }
}

private struct AppPermissionStatus {
  let microphone: AVAuthorizationStatus
  let screenRecording: Bool
  let accessibility: Bool
  let inputMonitoring: IOHIDAccessType

  static func current() -> AppPermissionStatus {
    AppPermissionStatus(
      microphone: AVCaptureDevice.authorizationStatus(for: .audio),
      screenRecording: CGPreflightScreenCaptureAccess(),
      accessibility: AXIsProcessTrusted(),
      inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    )
  }

  func isGranted(_ permission: AppPermission) -> Bool {
    switch permission {
    case .microphone:
      return microphone == .authorized
    case .screenRecording:
      return screenRecording
    case .accessibility:
      return accessibility
    case .inputMonitoring:
      return inputMonitoring == kIOHIDAccessTypeGranted
    }
  }
}

private enum AppPermission: String, CaseIterable, Identifiable {
  case microphone
  case screenRecording
  case accessibility
  case inputMonitoring

  var id: String { rawValue }

  var title: String {
    switch self {
    case .microphone: return "Microphone access"
    case .screenRecording: return "Screen recording access"
    case .accessibility: return "Accessibility access"
    case .inputMonitoring: return "Input Monitoring access"
    }
  }

  var detail: String {
    switch self {
    case .microphone:
      return "Required to record dictation audio and Hermes voice replies."
    case .screenRecording:
      return "Required when screen context or screenshot image context is enabled."
    case .accessibility:
      return "Required for global shortcut handling, selected text capture, and text insertion."
    case .inputMonitoring:
      return "Required by macOS for global key event monitoring used by shortcut detection."
    }
  }

  var requestTitle: String {
    switch self {
    case .microphone: return "Request Microphone"
    case .screenRecording: return "Request Screen Recording"
    case .accessibility: return "Request Accessibility"
    case .inputMonitoring: return "Request Input Monitoring"
    }
  }

  func openSettings() {
    let pane: String
    switch self {
    case .microphone:
      pane = "Privacy_Microphone"
    case .screenRecording:
      pane = "Privacy_ScreenCapture"
    case .accessibility:
      pane = "Privacy_Accessibility"
    case .inputMonitoring:
      pane = "Privacy_ListenEvent"
    }

    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
      NSWorkspace.shared.open(url)
    }
  }
}

#Preview {
  PermissionsView()
}
