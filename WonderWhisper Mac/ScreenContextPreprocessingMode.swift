import Foundation

enum ScreenContextPreprocessingMode: String, Codable, CaseIterable, Identifiable {
  case off
  case onDevice
  case llm

  var id: String { rawValue }

  var title: String {
    switch self {
    case .off: return "Off"
    case .onDevice: return "On-device"
    case .llm: return "LLM"
    }
  }

  var requiresLLM: Bool {
    self == .llm
  }

  var usesOnDeviceProcessing: Bool {
    self == .onDevice
  }

  static func fromLegacyOrganizeFlag(_ flag: Bool) -> ScreenContextPreprocessingMode {
    flag ? .llm : .off
  }
}
