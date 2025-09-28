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
    var organizeScreenContextOverride: Bool?

    init(id: UUID = UUID(),
         name: String,
         systemPrompt: String,
         userPrompt: String,
         shortcut: HotkeyManager.Shortcut? = nil,
         selection: HotkeyManager.Selection? = nil,
         llmModelOverride: String? = nil,
         llmProviderOverride: String? = nil,
         screenContextOverride: Bool? = nil,
         organizeScreenContextOverride: Bool? = nil) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.shortcut = shortcut
        self.selection = selection
        self.llmModelOverride = llmModelOverride
        self.llmProviderOverride = llmProviderOverride
        self.screenContextOverride = screenContextOverride
        self.organizeScreenContextOverride = organizeScreenContextOverride
    }
}

extension Array where Element == PromptConfiguration {
    func prompt(withID id: UUID?) -> PromptConfiguration? {
        guard let id else { return nil }
        return first { $0.id == id }
    }
}
