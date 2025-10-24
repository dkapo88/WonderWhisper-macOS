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
  var openrouterRoutingOverride: String?
  var voiceModelOverride: String?
  var voiceLanguageOverride: String?
  var screenContextOverride: Bool?
  var clipboardContextOverride: Bool?
  var selectedTextOverride: Bool?
  var screenContextCaptureOverride: ScreenContextCaptureMode?
  var screenContextPreprocessingOverride: ScreenContextPreprocessingMode?
  var includeScreenImageOverride: Bool?
  var triggerOnSelectedText: Bool
  var conversationModeEnabled: Bool
  var conversationContextMessages: Int

  init(id: UUID = UUID(),
       name: String,
       systemPrompt: String,
       userPrompt: String,
       shortcut: HotkeyManager.Shortcut? = nil,
       selection: HotkeyManager.Selection? = nil,
       llmModelOverride: String? = nil,
       llmProviderOverride: String? = nil,
       voiceModelOverride: String? = nil,
       voiceLanguageOverride: String? = nil,
       screenContextOverride: Bool? = nil,
       clipboardContextOverride: Bool? = nil,
       selectedTextOverride: Bool? = nil,
       screenContextCaptureOverride: ScreenContextCaptureMode? = nil,
       screenContextPreprocessingOverride: ScreenContextPreprocessingMode? = nil,
       includeScreenImageOverride: Bool? = nil,
       triggerOnSelectedText: Bool = false,
       conversationModeEnabled: Bool = false,
       conversationContextMessages: Int = 5) {
    self.id = id
    self.name = name
    self.systemPrompt = systemPrompt
    self.userPrompt = userPrompt
    self.shortcut = shortcut
    self.selection = selection
    self.llmModelOverride = llmModelOverride
    self.llmProviderOverride = llmProviderOverride
    self.voiceModelOverride = voiceModelOverride
    self.voiceLanguageOverride = voiceLanguageOverride
    self.screenContextOverride = screenContextOverride
    self.clipboardContextOverride = clipboardContextOverride
    self.selectedTextOverride = selectedTextOverride
    self.screenContextCaptureOverride = screenContextCaptureOverride
    self.screenContextPreprocessingOverride = screenContextPreprocessingOverride
    self.includeScreenImageOverride = includeScreenImageOverride
    self.triggerOnSelectedText = triggerOnSelectedText
    self.conversationModeEnabled = conversationModeEnabled
    self.conversationContextMessages = conversationContextMessages
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
    case openrouterRoutingOverride
    case voiceModelOverride
    case voiceLanguageOverride
    case screenContextOverride
    case clipboardContextOverride
    case selectedTextOverride
    case screenContextCaptureOverride
    case screenContextPreprocessingOverride
    case includeScreenImageOverride
    case triggerOnSelectedText
    case conversationModeEnabled
    case conversationContextMessages
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
    voiceModelOverride = try container.decodeIfPresent(String.self, forKey: .voiceModelOverride)
    voiceLanguageOverride = try container.decodeIfPresent(String.self, forKey: .voiceLanguageOverride)
    screenContextOverride = try container.decodeIfPresent(Bool.self, forKey: .screenContextOverride)
    clipboardContextOverride = try container.decodeIfPresent(Bool.self, forKey: .clipboardContextOverride)
    selectedTextOverride = try container.decodeIfPresent(Bool.self, forKey: .selectedTextOverride)
    screenContextCaptureOverride = try container.decodeIfPresent(ScreenContextCaptureMode.self, forKey: .screenContextCaptureOverride)
    triggerOnSelectedText = try container.decodeIfPresent(Bool.self, forKey: .triggerOnSelectedText) ?? false
    conversationModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .conversationModeEnabled) ?? false
    conversationContextMessages = try container.decodeIfPresent(Int.self, forKey: .conversationContextMessages) ?? 5
    includeScreenImageOverride = try container.decodeIfPresent(Bool.self, forKey: .includeScreenImageOverride)

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
    try container.encodeIfPresent(openrouterRoutingOverride, forKey: .openrouterRoutingOverride)
    try container.encodeIfPresent(voiceModelOverride, forKey: .voiceModelOverride)
    try container.encodeIfPresent(voiceLanguageOverride, forKey: .voiceLanguageOverride)
    try container.encodeIfPresent(screenContextOverride, forKey: .screenContextOverride)
    try container.encodeIfPresent(clipboardContextOverride, forKey: .clipboardContextOverride)
    try container.encodeIfPresent(selectedTextOverride, forKey: .selectedTextOverride)
    try container.encodeIfPresent(screenContextCaptureOverride, forKey: .screenContextCaptureOverride)
    try container.encodeIfPresent(screenContextPreprocessingOverride, forKey: .screenContextPreprocessingOverride)
    try container.encodeIfPresent(includeScreenImageOverride, forKey: .includeScreenImageOverride)
    try container.encode(triggerOnSelectedText, forKey: .triggerOnSelectedText)
    try container.encode(conversationModeEnabled, forKey: .conversationModeEnabled)
    try container.encode(conversationContextMessages, forKey: .conversationContextMessages)
  }
}

extension Array where Element == PromptConfiguration {
    func prompt(withID id: UUID?) -> PromptConfiguration? {
        guard let id else { return nil }
        return first { $0.id == id }
    }
}
