import Testing
import CoreGraphics
@testable import HermesWhisper

struct PromptBuilderTests {

    @Test func buildUserMessageIncludesAllContext() {
        let message = PromptBuilder.buildUserMessage(
            transcription: "Hello world",
            selectedText: "Selected text",
            activeTextField: "Existing text in field",
            appName: "TextEdit",
            screenContents: "Screen OCR content",
            customVocabulary: "Vocab1, Vocab2",
            clipboardText: "Clipboard"
        )

        // Check INPUT block structure
        #expect(message.contains("<INPUT>"))
        #expect(message.contains("<TRANSCRIPT>\nHello world\n</TRANSCRIPT>"))
        #expect(message.contains("</INPUT>"))

        // Check CONTEXT block structure
        #expect(message.contains("<CONTEXT type=\"reference-only\">"))
        #expect(message.contains("<ACTIVE_APPLICATION>TextEdit</ACTIVE_APPLICATION>"))
        #expect(message.contains("<ACTIVE_TEXT_FIELD>\nExisting text in field\n</ACTIVE_TEXT_FIELD>"))
        #expect(message.contains("<SCREEN_CONTENTS>\nScreen OCR content\n</SCREEN_CONTENTS>"))
        #expect(message.contains("<SELECTED_TEXT>\nSelected text\n</SELECTED_TEXT>"))
        #expect(message.contains("<CLIPBOARD>\nClipboard\n</CLIPBOARD>"))
        #expect(message.contains("<VOCABULARY>Vocab1, Vocab2</VOCABULARY>"))
        #expect(message.contains("</CONTEXT>"))
    }

    @Test func buildUserMessageOmitsEmptyContextFields() {
        let message = PromptBuilder.buildUserMessage(
            transcription: "Hello world",
            selectedText: nil,
            activeTextField: nil,
            appName: nil,
            screenContents: nil,
            customVocabulary: nil
        )

        // Should have INPUT block
        #expect(message.contains("<INPUT>"))
        #expect(message.contains("<TRANSCRIPT>\nHello world\n</TRANSCRIPT>"))
        #expect(message.contains("</INPUT>"))

        // Should NOT have CONTEXT block when all context is empty
        #expect(!message.contains("<CONTEXT"))
        #expect(!message.contains("<ACTIVE_TEXT_FIELD>"))
        #expect(!message.contains("<SELECTED_TEXT>"))
        #expect(!message.contains("<SCREEN_CONTENTS>"))
        #expect(!message.contains("<VOCABULARY>"))
    }

    @Test func buildUserMessageIncludesPartialContext() {
        let message = PromptBuilder.buildUserMessage(
            transcription: "Hello world",
            selectedText: nil,
            activeTextField: "Some field text",
            appName: "TextEdit",
            screenContents: nil,
            customVocabulary: nil
        )

        // Should have CONTEXT block with only non-empty fields
        #expect(message.contains("<CONTEXT type=\"reference-only\">"))
        #expect(message.contains("<ACTIVE_APPLICATION>TextEdit</ACTIVE_APPLICATION>"))
        #expect(message.contains("<ACTIVE_TEXT_FIELD>\nSome field text\n</ACTIVE_TEXT_FIELD>"))
        #expect(!message.contains("<SELECTED_TEXT>"))
        #expect(!message.contains("<SCREEN_CONTENTS>"))
        #expect(!message.contains("<VOCABULARY>"))
    }

    @Test func buildUserMessageIncludesScreenContextTermsInsteadOfRawScreenContents() {
        let message = PromptBuilder.buildUserMessage(
            transcription: "Please spell the product names correctly",
            selectedText: nil,
            activeTextField: nil,
            appName: "Slack",
            screenContents: "Raw OCR paragraph that should not be sent when terms exist",
            screenContextTerms: "Dane Kapoor, OpenRouter Voice, Soniox V4, CORE-759",
            customVocabulary: nil
        )

        #expect(message.contains("<SCREEN_CONTEXT_TERMS>\nDane Kapoor, OpenRouter Voice, Soniox V4, CORE-759\n</SCREEN_CONTEXT_TERMS>"))
        #expect(!message.contains("<SCREEN_CONTENTS>"))
        #expect(!message.contains("Raw OCR paragraph"))
    }

    @Test func buildSystemMessageIncludesOutputTag() {
        let message = PromptBuilder.buildSystemMessage(
            base: "You are a helpful assistant",
            customVocabulary: "",
            customSpelling: ""
        )

        #expect(message.contains("<OUTPUT>"))
        #expect(message.contains("</OUTPUT>"))
        #expect(!message.contains("<FORMATTED_TEXT>"))
    }

    @Test func voiceVocabularyKeytermsIncludeCustomTermsAndReplacementTargets() {
        let terms = VoiceVocabularyKeyterms.terms(
            customVocabulary: "HermesWhisper, Hapana\nEzypay, hermeswhisper",
            spellingCorrections: "home's wispa -> HermesWhisper\nbisso -> Biso"
        )

        #expect(terms == ["HermesWhisper", "Hapana", "Ezypay", "Biso"])
    }

    @Test func voiceVocabularyKeytermsDropTermsOverProviderLimit() {
        let longTerm = String(repeating: "A", count: VoiceVocabularyKeyterms.maxCharactersPerTerm + 1)
        let terms = VoiceVocabularyKeyterms.terms(
            customVocabulary: "Valid Term, \(longTerm)",
            spellingCorrections: ""
        )

        #expect(terms == ["Valid Term"])
    }

    @Test func vocabularyTextCorrectorFixesNearMissProperNouns() {
        let corrected = VocabularyTextCorrector.apply(
            to: "It should be okay with Ezipay, then I will talk to McKenzie.",
            vocabulary: "Ezypay, Makenzie, Hapana"
        )

        #expect(corrected == "It should be okay with Ezypay, then I will talk to Makenzie.")
    }

    @Test func vocabularyTextCorrectorAvoidsDistantCommonWords() {
        let corrected = VocabularyTextCorrector.apply(
            to: "This payment report is ready.",
            vocabulary: "Tais, Hapana"
        )

        #expect(corrected == "This payment report is ready.")
    }
}

struct StructuredScreenTextBuilderTests {

    @Test func structuredBuilderProducesParagraphsAndKeyTerms() {
        let blocks: [ScreenTextBlock] = [
            .init(text: "PROJECT PLAN", boundingBox: CGRect(x: 0.1, y: 0.82, width: 0.7, height: 0.05)),
            .init(text: "Timeline March 2025", boundingBox: CGRect(x: 0.1, y: 0.75, width: 0.7, height: 0.04)),
            .init(text: "Attendees: Dane Kapoor, Apple Design", boundingBox: CGRect(x: 0.1, y: 0.69, width: 0.8, height: 0.04)),
            .init(text: "- Finalize spec for HermesWhisper", boundingBox: CGRect(x: 0.09, y: 0.63, width: 0.7, height: 0.04)),
            .init(text: "- Book venue in San Francisco", boundingBox: CGRect(x: 0.09, y: 0.58, width: 0.7, height: 0.04)),
            .init(text: "Next review scheduled 3/12", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.7, height: 0.04))
        ]

        let builder = StructuredScreenTextBuilder(blocks: blocks)
        let formatted = builder.build() ?? ""
        #expect(formatted.contains("PROJECT PLAN"))
        #expect(formatted.contains("Timeline March 2025"))
        #expect(formatted.contains("• Finalize spec for HermesWhisper"))
        #expect(formatted.contains("• Book venue in San Francisco"))
        #expect(formatted.contains("Key Terms:"), "Formatted output: \(formatted)")
    }
}

struct ScreenContextTermExtractorTests {

    @Test func extractorKeepsNamesProductsAcronymsAndTicketIds() {
        let text = """
        Slack thread with Dane Kapoor and Luis about HermesWhisper.
        Please compare OpenRouter Voice, Soniox V4, Apple Intelligence, and CORE-759.
        The HermesWhisper context path should preserve API names and GPT-4o-mini-transcribe.
        """

        let terms = ScreenContextTermExtractor.extract(from: text, limit: 20)

        #expect(terms.contains("Dane Kapoor"), "Terms: \(terms)")
        #expect(terms.contains("Luis"), "Terms: \(terms)")
        #expect(terms.contains("HermesWhisper"), "Terms: \(terms)")
        #expect(terms.contains("OpenRouter Voice"), "Terms: \(terms)")
        #expect(terms.contains("Soniox V4"), "Terms: \(terms)")
        #expect(terms.contains("Apple Intelligence"), "Terms: \(terms)")
        #expect(terms.contains("CORE-759"), "Terms: \(terms)")
        #expect(terms.contains("HermesWhisper"), "Terms: \(terms)")
        #expect(terms.contains("GPT-4o-mini-transcribe"), "Terms: \(terms)")
    }

    @Test func preprocessorFallsBackToLocalTermsWhenAppleIntelligenceIsDisabled() async {
        let preprocessor = ScreenContextPreprocessor(useAppleIntelligence: false)

        let result = await preprocessor.preprocess(
            ocrText: "Dane Kapoor is testing OpenRouter Voice with Soniox V4 in HermesWhisper."
        )

        #expect(result?.method == .localKeywords)
        #expect(result?.contextText.contains("Dane Kapoor") == true)
        #expect(result?.contextText.contains("OpenRouter Voice") == true)
        #expect(result?.contextText.contains("Soniox V4") == true)
        #expect(result?.contextText.contains("HermesWhisper") == true)
    }

    @Test func normalizerFiltersLikelyOCRNoiseFromModelOutput() {
        let noisy = """
        spelling and grammar check, information retrieval, data analysis, communication
        technical support, data management, error correction, data validation, Sarah Dunne
        v2, Sonall, you, DB, Dane, Kaln, That, me, thank, going, squad, memberships
        team, let, 50AM, thi5, 13m, gener31, IVII, necess3rilv, Typic311y
        individu31, c13rification, 3n, BC, my, double, check, tickets, just, all
        """

        let terms = ScreenContextTermExtractor.normalizeCommaSeparated(noisy, limit: 80)

        #expect(terms.contains("Sarah Dunne"), "Terms: \(terms)")
        #expect(terms.contains("v2"), "Terms: \(terms)")
        #expect(terms.contains("DB"), "Terms: \(terms)")
        #expect(!terms.contains("50AM"), "Terms: \(terms)")
        #expect(!terms.contains("thi5"), "Terms: \(terms)")
        #expect(!terms.contains("gener31"), "Terms: \(terms)")
        #expect(!terms.contains("IVII"), "Terms: \(terms)")
        #expect(!terms.contains("necess3rilv"), "Terms: \(terms)")
        #expect(!terms.contains("Typic311y"), "Terms: \(terms)")
        #expect(!terms.contains("individu31"), "Terms: \(terms)")
        #expect(!terms.contains("c13rification"), "Terms: \(terms)")
        #expect(!terms.contains("you"), "Terms: \(terms)")
        #expect(!terms.contains("thank"), "Terms: \(terms)")
        #expect(!terms.contains("team"), "Terms: \(terms)")
        #expect(!terms.contains("just"), "Terms: \(terms)")
    }

    @Test func normalizerRepairsCloseMatchesToKnownCorrectionHints() {
        let terms = ScreenContextTermExtractor.normalizeCommaSeparated(
            "OpenR0uter Voice, Soniox V4, GPT-4o-mini-transcribe",
            limit: 10,
            correctionHints: ["OpenRouter Voice", "Soniox V4", "GPT-4o-mini-transcribe"]
        )

        #expect(terms.contains("OpenRouter Voice"), "Terms: \(terms)")
        #expect(terms.contains("Soniox V4"), "Terms: \(terms)")
        #expect(terms.contains("GPT-4o-mini-transcribe"), "Terms: \(terms)")
        #expect(!terms.contains("OpenR0uter Voice"), "Terms: \(terms)")
    }
}
