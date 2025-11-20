import Foundation

struct PromptBuilder {
    // Mirrors Android TextProcessingUtils.buildStructuredSystemMessage
    static func buildSystemMessage(base: String, customVocabulary: String, customSpelling: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        out += "<SYSTEM_PROMPT>\n"
        out += trimmedBase
        out += "\n</SYSTEM_PROMPT>\n\n"

        out += "<CONTEXT_USAGE_INSTRUCTIONS>\n"
        out += "Your task is to work ONLY with the content within the '<TRANSCRIPT>' tags.\n\n"
        out += "IMPORTANT: The following context information is ONLY for reference:\n"
        out += "- '<ACTIVE_APPLICATION>': The application currently in focus\n"
        out += "- '<ACTIVE_TEXT_FIELD>': The full contents of the focused text field\n"
        out += "- '<SCREEN_CONTENTS>': Guidance for interpreting the attached screen capture\n"
        out += "- '<SELECTED_TEXT>': Text that was selected when recording started\n"
        out += "- '<VOCABULARY>': Important words that should be recognized correctly\n\n"
        out += "Use this context to:\n"
        out += "- Fix transcription errors by referencing names, terms, or content visible in the capture\n"
        out += "- Understand the user's intent and environment\n"
        out += "- Prioritize spelling and forms from context over potentially incorrect transcription\n\n"
        out += "A screenshot of the relevant window or screen is attached separately. Use the image in combination with '<SCREEN_CONTENTS>' guidance.\n\n"
        out += "The <TRANSCRIPT> content is your primary focus - enhance it using context as reference only.\n"
        out += "</CONTEXT_USAGE_INSTRUCTIONS>\n\n"

        // Note: As of the updated prompt structure, do NOT inject vocabulary content into the system message.
        // Leave any <VOCABULARY> tags in the system message as reference/instruction placeholders only.
        // The actual vocabulary content (with tags) now lives in the user message.
        // Note: customSpelling (text replacements) are NOT included in the prompt.
        out += "<VOCABULARY>\n"
        out += ""
        out += "\n</VOCABULARY>\n\n"

        out += "**Output Format:**\n"
        out += "Place your entire, final output inside `<FORMATTED_TEXT>` tags and nothing else.\n\n"
        out += "**Example:**\n"
        out += "Output: <FORMATTED_TEXT>We need $3,000 to analyse the data.</FORMATTED_TEXT>"
        return out
    }

    // Mirrors Android TextProcessingUtils.buildStructuredUserMessage
    // Now includes <VOCABULARY> in the user message alongside other dynamic content.
    static func buildUserMessage(transcription: String,
                                 selectedText: String?,
                                 activeTextField: String?,
                                 appName: String?,
                                 screenContents: String?,
                                 customVocabulary: String?,
                                 clipboardText: String? = nil) -> String {
        var out = ""
        out += "<TRANSCRIPT>\n"
        out += transcription
        out += "\n</TRANSCRIPT>\n\n"

        out += "<ACTIVE_APPLICATION>\n"
        out += (appName?.isEmpty == false) ? (appName ?? "Unknown") : "Unknown"
        out += "\n</ACTIVE_APPLICATION>\n\n"

        out += "<ACTIVE_TEXT_FIELD>\n"
        out += (activeTextField ?? "")
        out += "\n</ACTIVE_TEXT_FIELD>\n\n"

        out += "<SCREEN_CONTENTS>\n"
        out += (screenContents ?? "")
        out += "\n</SCREEN_CONTENTS>\n\n"

        out += "<SELECTED_TEXT>\n"
        out += (selectedText ?? "")
        out += "\n</SELECTED_TEXT>\n\n"

        if let clipboardText, !clipboardText.isEmpty {
            out += "<CLIPBOARD>\n"
            out += clipboardText
            out += "\n</CLIPBOARD>\n\n"
        }

        // Include vocabulary here (moved from system message)
        out += "<VOCABULARY>\n"
        let trimmedVocab = (customVocabulary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVocab.isEmpty {
            let separators: Set<Character> = [",", "\n", "\r"]
            let items = trimmedVocab.split(whereSeparator: { separators.contains($0) })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !items.isEmpty {
                out += items.joined(separator: ", ")
            }
        }
        out += "\n</VOCABULARY>\n\n"
        return out
    }

    // Render a user-configurable system prompt template WITHOUT injecting vocabulary content.
    // Existing <VOCABULARY> tags are left untouched as reference/instruction placeholders.
    static func renderSystemPrompt(template: String, customVocabulary: String) -> String {
        return template
    }
}
