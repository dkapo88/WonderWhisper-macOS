import Foundation

struct SimplePromptTemplate: Identifiable, Codable, Equatable {
  enum Source: String, Codable {
    case builtIn
    case custom
  }

  let id: UUID
  var name: String
  var rules: String
  var footer: String
  var source: Source

  init(id: UUID = UUID(),
       name: String,
       rules: String,
       footer: String,
       source: Source = .custom) {
    self.id = id
    self.name = name
    self.rules = rules
    self.footer = footer
    self.source = source
  }

  var isBuiltIn: Bool {
    source == .builtIn
  }
}

enum SimplePromptTemplateLibrary {
  static let defaultTemplateID = UUID(uuidString: "F7F4A0D4-6352-46CC-9B22-7903D9A5A58A")!
  static let highCleanupTemplateID = UUID(uuidString: "9B54BB99-B491-4D97-B4B2-7A6E52564082")!

  static var builtInDictationTemplates: [SimplePromptTemplate] {
    [
      SimplePromptTemplate(
        id: defaultTemplateID,
        name: "Default: medium cleanup prompt",
        rules: SimpleModeDefaults.defaultRules(for: .dictation),
        footer: SimpleModeDefaults.systemFooter(for: .dictation),
        source: .builtIn
      ),
      SimplePromptTemplate(
        id: highCleanupTemplateID,
        name: "High cleanup",
        rules: highCleanupRules,
        footer: SimpleModeDefaults.systemFooter(for: .dictation),
        source: .builtIn
      )
    ]
  }

  private static let highCleanupRules = """
- Output in british english
- reformat for brevity and for somebody to read only once
- keep profanity
- use $ symbols for currency
- prefer nemericals for numbers
- use symbols where possible
- structure into short paragraphs
- where appropriate and possible, aggressivle use bullet points and numbered lists to improve readability, clarity, and brevity.
- use sub bullets for even better structure when needed
- turn my rambling transcriptions and thought dumps into a clear structured piece of writing
- Detect what app I'm using and if it's an email, structure it for an email appropriately. Whatever app I'm using, structure the content appropriately for the app. (Spark is my usual email app)
- Make sure you remove all filler words.
- Do not use em dashes. I hate to use em dashes.
- If the <ACTIVE_APPLICATION> is = “Slack” OR slack, I generally like to use mentions when using first names, so it would be great if you appended an @ to the beginning of first names. for eg Dane = @dane
- do not append @ to first names if the active application is not slack
- Try and keep a similar meaning, intent and natural tone as the original transcription.
"""
}
