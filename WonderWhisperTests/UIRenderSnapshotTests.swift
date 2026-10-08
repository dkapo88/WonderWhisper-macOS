import AppKit
import Foundation
import SwiftUI
import Testing
@testable import WonderWhisper

/// Renders the main screens offscreen to PNG (dark mode) for visual review. Opt-in: runs only
/// when `WW_RENDER_DIR` is set, e.g.
/// `TEST_RUNNER_WW_RENDER_DIR=/path xcodebuild test -only-testing:WonderWhisperTests/UIRenderSnapshotTests`.
@MainActor
struct UIRenderSnapshotTests {
  private static let outputDirectory = ProcessInfo.processInfo.environment["WW_RENDER_DIR"]

  @Test(.enabled(if: outputDirectory != nil))
  func renderScreens() async throws {
    let directory = try #require(Self.outputDirectory)
    try FileManager.default.createDirectory(
      atPath: directory,
      withIntermediateDirectories: true
    )
    let vm = try await liveViewModel()

    // Taller than the real window so each pane renders top to bottom in one image.
    let settingsSize = CGSize(width: DesignTokens.Width.settingsWindow, height: 1500)
    let router = SettingsRouter.shared
    let panes: [(String, AnyView)] = [
      ("settings-1-general", AnyView(GeneralSettingsPane(vm: vm))),
      ("settings-2-transcription", AnyView(TranscriptionSettingsPane(vm: vm))),
      ("settings-3-models", AnyView(ModelsSettingsPane(vm: vm))),
      ("settings-4-audio", AnyView(AudioSettingsPane(vm: vm))),
      ("settings-5-meetings", AnyView(MeetingSettingsPane(
        coordinator: vm.meetingCoordinator,
        favoriteModels: vm.favoriteOpenRouterModels
      ))),
      ("settings-6-shortcuts", AnyView(ShortcutsSettingsPane(vm: vm))),
      ("settings-8-permissions", AnyView(PermissionsView()))
    ]
    for (name, view) in panes {
      try await render(view, size: settingsSize, to: directory, name: name)
    }
    for integration in SettingsTab.Integration.allCases {
      router.selectedIntegration = integration
      try await render(
        AnyView(IntegrationsSettingsPane(vm: vm, router: router)),
        size: settingsSize,
        to: directory,
        name: "settings-7-integrations-\(integration.rawValue)"
      )
    }

    let mainSize = CGSize(width: 1100, height: 886)
    let original = vm.simpleSidebarSelection
    for item in SimpleSidebarItem.displayOrder {
      vm.simpleSidebarSelection = item
      try await render(
        AnyView(ContentView(vm: vm)),
        size: mainSize,
        to: directory,
        name: "main-\(SimpleSidebarItem.displayOrder.firstIndex(of: item) ?? 0)-\(item.rawValue)",
        includeTitlebar: true
      )
    }
    vm.simpleSidebarSelection = original

    // The real sidebar is vibrant and can't be cached offscreen; render its content on a
    // plain background instead.
    try await render(
      AnyView(
        MainSidebarList(selection: .constant(.meetings))
          .scrollContentBackground(.hidden)
          .background(Color(nsColor: .underPageBackgroundColor))
      ),
      size: CGSize(width: 220, height: 420),
      to: directory,
      name: "main-sidebar"
    )
    try await render(
      AnyView(OpenRouterModelBrowserView(vm: vm)),
      size: CGSize(width: 700, height: 600),
      to: directory,
      name: "sheet-model-browser"
    )
    try await render(
      AnyView(SimpleHistoryView(vm: vm)),
      size: CGSize(width: 860, height: 700),
      to: directory,
      name: "content-history"
    )
  }

  private func liveViewModel() async throws -> DictationViewModel {
    for _ in 0..<50 {
      if let vm = SettingsRouter.shared.viewModel { return vm }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    return try #require(SettingsRouter.shared.viewModel)
  }

  private func render(
    _ view: AnyView,
    size: CGSize,
    to directory: String,
    name: String,
    includeTitlebar: Bool = false
  ) async throws {
    let styleMask: NSWindow.StyleMask = includeTitlebar
      ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
      : [.borderless]
    let window = NSWindow(
      contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
      styleMask: styleMask,
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
    host.frame = NSRect(origin: .zero, size: size)
    if includeTitlebar {
      let controller = NSHostingController(rootView: view.preferredColorScheme(.dark))
      window.contentViewController = controller
      window.setContentSize(size)
    } else {
      window.contentView = host
    }
    window.orderFrontRegardless()
    window.alphaValue = 0.01
    try await Task.sleep(nanoseconds: includeTitlebar ? 2_500_000_000 : 1_200_000_000)

    guard let target = includeTitlebar ? window.contentView?.superview : window.contentView else {
      return
    }
    target.layoutSubtreeIfNeeded()
    guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
    target.cacheDisplay(in: target.bounds, to: rep)
    window.orderOut(nil)
    window.close()
    let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
    try rep.representation(using: .png, properties: [:])?.write(to: url)
  }
}
