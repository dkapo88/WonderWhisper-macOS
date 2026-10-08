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
    SettingsPage {
      Section {
        ForEach(requiredPermissions) { permission in
          PermissionRow(
            permission: permission,
            isGranted: permissions.isGranted(permission),
            isRequesting: isRequestingMicrophone && permission == .microphone,
            requestAction: { request(permission) },
            settingsAction: { permission.openSettings() }
          )
        }
      } header: {
        Text("macOS permissions")
      } footer: {
        Text("WonderWhisper needs these for dictation, meeting audio, context capture, "
          + "shortcuts, and text insertion. Status refreshes when you return to the app.")
          .settingsFootnote()
      }
    }
    .onAppear(perform: refresh)
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      refresh()
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

extension PermissionsView {
  /// Titles of required permissions that are not granted yet, for the main-window banner.
  static func missingPermissionTitles() -> [String] {
    let status = AppPermissionStatus.current()
    return AppPermission.allCases.filter { !status.isGranted($0) }.map(\.title)
  }
}

private struct PermissionRow: View {
  let permission: AppPermission
  let isGranted: Bool
  let isRequesting: Bool
  let requestAction: () -> Void
  let settingsAction: () -> Void

  var body: some View {
    LabeledContent {
      if isGranted {
        StatusBadge(.ok, "Enabled")
      } else {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
          StatusBadge(.warning, "Needs access")
          Button(action: requestAction) {
            if isRequesting {
              ProgressView().controlSize(.small)
            } else {
              Text("Request")
            }
          }
          .disabled(isRequesting)
          .accessibilityLabel(permission.requestTitle)
          Button("Open Settings…", action: settingsAction)
            .accessibilityLabel("Open System Settings for \(permission.title)")
        }
      }
    } label: {
      Text(permission.title)
      Text(permission.detail)
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
    case .microphone: return "Microphone"
    case .screenRecording: return "Screen Recording"
    case .accessibility: return "Accessibility"
    case .inputMonitoring: return "Input Monitoring"
    }
  }

  var detail: String {
    switch self {
    case .microphone:
      return "Required to record dictation, Hermes voice replies, and your side of meetings."
    case .screenRecording:
      return "Required for meeting system audio and when screen context or screenshots are enabled."
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
