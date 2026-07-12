import Foundation

struct PromptBuilder {
    // Builds a structured user message with clear INPUT/CONTEXT hierarchy.
    // INPUT contains the primary content to transform.
    // CONTEXT contains reference-only material (only non-empty fields are included).
    static func buildUserMessage(transcription: String,
                                 selectedText: String?,
                                 activeTextField: String?,
                                 appName: String?,
                                 screenContents: String?,
                                 screenContextTerms: String? = nil,
                                 customVocabulary: String?,
                                 clipboardText: String? = nil) -> String {
        var out = ""

        // PRIMARY INPUT - this is what the LLM should transform
        out += "<INPUT>\n"
        out += "<TRANSCRIPT>\n"
        out += transcription
        out += "\n</TRANSCRIPT>\n"
        out += "</INPUT>\n\n"

        // CONTEXT - reference-only material, only include non-empty fields
        var contextParts: [String] = []

        // App name (always include if available)
        let effectiveAppName = appName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? appName : nil
        if let app = effectiveAppName {
            contextParts.append("<ACTIVE_APPLICATION>\(app)</ACTIVE_APPLICATION>")
        }

        // Active text field
        if let field = activeTextField?.trimmingCharacters(in: .whitespacesAndNewlines), !field.isEmpty {
            contextParts.append("<ACTIVE_TEXT_FIELD>\n\(field)\n</ACTIVE_TEXT_FIELD>")
        }

        // Selected text
        if let selected = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty {
            contextParts.append("<SELECTED_TEXT>\n\(selected)\n</SELECTED_TEXT>")
        }

        // Screen context, preferring a distilled spelling term list over raw OCR.
        if let terms = screenContextTerms?.trimmingCharacters(in: .whitespacesAndNewlines), !terms.isEmpty {
            contextParts.append("<SCREEN_CONTEXT_TERMS>\n\(terms)\n</SCREEN_CONTEXT_TERMS>")
        } else if let screen = screenContents?.trimmingCharacters(in: .whitespacesAndNewlines), !screen.isEmpty {
            contextParts.append("<SCREEN_CONTENTS>\n\(screen)\n</SCREEN_CONTENTS>")
        }

        // Clipboard
        if let clipboard = clipboardText?.trimmingCharacters(in: .whitespacesAndNewlines), !clipboard.isEmpty {
            contextParts.append("<CLIPBOARD>\n\(clipboard)\n</CLIPBOARD>")
        }

        // Vocabulary
        let trimmedVocab = (customVocabulary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVocab.isEmpty {
            let separators: Set<Character> = [",", "\n", "\r"]
            let items = trimmedVocab.split(whereSeparator: { separators.contains($0) })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !items.isEmpty {
                contextParts.append("<VOCABULARY>\(items.joined(separator: ", "))</VOCABULARY>")
            }
        }

        // Only add CONTEXT block if there's at least one context item
        if !contextParts.isEmpty {
            out += "<CONTEXT type=\"reference-only\">\n"
            out += contextParts.joined(separator: "\n")
            out += "\n</CONTEXT>\n"
        }

        return out
    }
}
