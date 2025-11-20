import Testing
import CoreGraphics
@testable import WonderWhisper_Mac

struct PromptBuilderTests {

    @Test func buildUserMessageIncludesActiveTextField() {
        let message = PromptBuilder.buildUserMessage(
            transcription: "Hello world",
            selectedText: "Selected text",
            activeTextField: "Existing text in field",
            appName: "TextEdit",
            screenContents: "Screen OCR content",
            customVocabulary: "Vocab1, Vocab2",
            clipboardText: "Clipboard"
        )

        #expect(message.contains("<TRANSCRIPT>\nHello world\n</TRANSCRIPT>"))
        #expect(message.contains("<ACTIVE_APPLICATION>\nTextEdit\n</ACTIVE_APPLICATION>"))
        #expect(message.contains("<ACTIVE_TEXT_FIELD>\nExisting text in field\n</ACTIVE_TEXT_FIELD>"))
        #expect(message.contains("<SCREEN_CONTENTS>\nScreen OCR content\n</SCREEN_CONTENTS>"))
        #expect(message.contains("<SELECTED_TEXT>\nSelected text\n</SELECTED_TEXT>"))
        #expect(message.contains("<CLIPBOARD>\nClipboard\n</CLIPBOARD>"))
        #expect(message.contains("<VOCABULARY>\nVocab1, Vocab2\n</VOCABULARY>"))
    }

    @Test func buildUserMessageHandlesMissingActiveTextField() {
        let message = PromptBuilder.buildUserMessage(
            transcription: "Hello world",
            selectedText: nil,
            activeTextField: nil,
            appName: nil,
            screenContents: nil,
            customVocabulary: nil
        )

        #expect(message.contains("<ACTIVE_TEXT_FIELD>\n\n</ACTIVE_TEXT_FIELD>"))
    }
}

struct StructuredScreenTextBuilderTests {

    @Test func structuredBuilderProducesParagraphsAndKeyTerms() {
        let blocks: [ScreenTextBlock] = [
            .init(text: "PROJECT PLAN", boundingBox: CGRect(x: 0.1, y: 0.82, width: 0.7, height: 0.05)),
            .init(text: "Timeline March 2025", boundingBox: CGRect(x: 0.1, y: 0.75, width: 0.7, height: 0.04)),
            .init(text: "Attendees: Dane Kapoor, Apple Design", boundingBox: CGRect(x: 0.1, y: 0.69, width: 0.8, height: 0.04)),
            .init(text: "- Finalize spec for WonderWhisper", boundingBox: CGRect(x: 0.09, y: 0.63, width: 0.7, height: 0.04)),
            .init(text: "- Book venue in San Francisco", boundingBox: CGRect(x: 0.09, y: 0.58, width: 0.7, height: 0.04)),
            .init(text: "Next review scheduled 3/12", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.04))
        ]

        let builder = StructuredScreenTextBuilder(blocks: blocks)
        let formatted = builder.build() ?? ""
        #expect(formatted.contains("PROJECT PLAN"))
        #expect(formatted.contains("Timeline March 2025"))
        #expect(formatted.contains("• Finalize spec for WonderWhisper"))
        #expect(formatted.contains("• Book venue in San Francisco"))
        #expect(formatted.contains("Key Terms:"), "Formatted output: \(formatted)")
    }
}
