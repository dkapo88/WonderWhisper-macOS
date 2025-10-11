import Foundation

struct PromptConfiguration: Identifiable, Codable, Hashable {
  var id: UUID
  var name: String
  var systemPrompt: String
  var userPrompt: String
  var shortcut: HotkeyManager.Shortcut?
  var selection: HotkeyManager.Selection?
  var llmModelOverride: String?
  var llmProviderOverride: String?
  var screenContextOverride: Bool?
  var clipboardContextOverride: Bool?
  var screenContextPreprocessingOverride: ScreenContextPreprocessingMode?
  var triggerOnSelectedText: Bool

  init(id: UUID = UUID(),
       name: String,
       systemPrompt: String,
       userPrompt: String,
       shortcut: HotkeyManager.Shortcut? = nil,
       selection: HotkeyManager.Selection? = nil,
       llmModelOverride: String? = nil,
       llmProviderOverride: String? = nil,
       screenContextOverride: Bool? = nil,
       clipboardContextOverride: Bool? = nil,
       screenContextPreprocessingOverride: ScreenContextPreprocessingMode? = nil,
       triggerOnSelectedText: Bool = false) {
    self.id = id
    self.name = name
    self.systemPrompt = systemPrompt
    self.userPrompt = userPrompt
    self.shortcut = shortcut
    self.selection = selection
    self.llmModelOverride = llmModelOverride
    self.llmProviderOverride = llmProviderOverride
    self.screenContextOverride = screenContextOverride
    self.clipboardContextOverride = clipboardContextOverride
    self.screenContextPreprocessingOverride = screenContextPreprocessingOverride
    self.triggerOnSelectedText = triggerOnSelectedText
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case systemPrompt
    case userPrompt
    case shortcut
    case selection
    case llmModelOverride
    case llmProviderOverride
    case screenContextOverride
    case clipboardContextOverride
    case screenContextPreprocessingOverride
    case triggerOnSelectedText
    case legacyOrganizeOverride = "organizeScreenContextOverride"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
    userPrompt = try container.decode(String.self, forKey: .userPrompt)
    shortcut = try container.decodeIfPresent(HotkeyManager.Shortcut.self, forKey: .shortcut)
    selection = try container.decodeIfPresent(HotkeyManager.Selection.self, forKey: .selection)
    llmModelOverride = try container.decodeIfPresent(String.self, forKey: .llmModelOverride)
    llmProviderOverride = try container.decodeIfPresent(String.self, forKey: .llmProviderOverride)
    screenContextOverride = try container.decodeIfPresent(Bool.self, forKey: .screenContextOverride)
    clipboardContextOverride = try container.decodeIfPresent(Bool.self, forKey: .clipboardContextOverride)
    triggerOnSelectedText = try container.decodeIfPresent(Bool.self, forKey: .triggerOnSelectedText) ?? false

    if let mode = try container.decodeIfPresent(ScreenContextPreprocessingMode.self, forKey: .screenContextPreprocessingOverride) {
      screenContextPreprocessingOverride = mode
    } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .legacyOrganizeOverride) {
      screenContextPreprocessingOverride = ScreenContextPreprocessingMode.fromLegacyOrganizeFlag(legacy)
    } else {
      screenContextPreprocessingOverride = nil
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(systemPrompt, forKey: .systemPrompt)
    try container.encode(userPrompt, forKey: .userPrompt)
    try container.encodeIfPresent(shortcut, forKey: .shortcut)
    try container.encodeIfPresent(selection, forKey: .selection)
    try container.encodeIfPresent(llmModelOverride, forKey: .llmModelOverride)
    try container.encodeIfPresent(llmProviderOverride, forKey: .llmProviderOverride)
    try container.encodeIfPresent(screenContextOverride, forKey: .screenContextOverride)
    try container.encodeIfPresent(clipboardContextOverride, forKey: .clipboardContextOverride)
    try container.encodeIfPresent(screenContextPreprocessingOverride, forKey: .screenContextPreprocessingOverride)
    try container.encode(triggerOnSelectedText, forKey: .triggerOnSelectedText)
  }
}

extension Array where Element == PromptConfiguration {
    func prompt(withID id: UUID?) -> PromptConfiguration? {
        guard let id else { return nil }
        return first { $0.id == id }
    }
}
