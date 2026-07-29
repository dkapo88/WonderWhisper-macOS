//
//  WonderWhisperTests.swift
//  WonderWhisperTests
//
//  Created by Dane Kapoor on 4/9/25.
//

import Testing
@testable import WonderWhisper

struct WonderWhisperTests {

    @Test func keychainSecretNormalizationRejectsMalformedGroqKeys() {
        #expect(KeychainService.normalizedSecret("  gsk_test_key_1234567890\n") == "gsk_test_key_1234567890")
        #expect(KeychainService.isPlausibleGroqAPIKey("gsk_test_key_1234567890"))
        #expect(!KeychainService.isPlausibleGroqAPIKey("Bearer gsk_test_key_1234567890"))
        #expect(!KeychainService.isPlausibleGroqAPIKey("gsk_test key 1234567890"))
        #expect(!KeychainService.isPlausibleGroqAPIKey("sk-not-a-groq-key"))
    }

    /// Rich-text paste: bullets and numbered lines become real lists, inline markdown
    /// converts, and raw HTML in the transcript is escaped rather than injected.
    @Test func pasteHTMLBuildsListsAndEscapes() throws {
        let text = """
        Tomorrow I need to:

        - go to the **shops**
        - comb my hair

        1. first
        2. second

        a < b & c
        """
        let data = try #require(InsertionService.htmlForPaste(from: text))
        let html = try #require(String(data: data, encoding: .utf8))
        #expect(html.contains("<p>Tomorrow I need to:</p>"))
        #expect(html.contains("<ul><li>go to the <strong>shops</strong></li><li>comb my hair</li></ul>"))
        #expect(html.contains("<ol><li>first</li><li>second</li></ol>"))
        #expect(html.contains("<p>a &lt; b &amp; c</p>"))
        // Bare asterisks in prose (arithmetic) must survive, not become <em>.
        let math = try #require(InsertionService.htmlForPaste(from: "5 * 3 and 2 * 4 items"))
        #expect(String(data: math, encoding: .utf8)?.contains("5 * 3 and 2 * 4 items") == true)
        #expect(InsertionService.htmlForPaste(from: "   \n ") == nil)
    }

    /// The gateway travels with the model string: a `vercel:` prefix must swap endpoint,
    /// key alias, and the on-the-wire model together — a Vercel endpoint hit with the
    /// OpenRouter key is a guaranteed 401, and a `vercel:`-prefixed wire ID is a 404.
    @Test func llmRouteDerivesGatewayFromTheModelID() {
        let vercel = AppConfig.llmRoute(for: "vercel:openai/gpt-4o")
        #expect(vercel.endpoint.absoluteString
            == "https://ai-gateway.vercel.sh/v1/chat/completions")
        #expect(vercel.keyAlias == AppConfig.vercelGatewayAPIKeyAlias)
        #expect(vercel.requestModel == "openai/gpt-4o")

        let openrouter = AppConfig.llmRoute(for: "moonshotai/kimi-k2-instruct")
        #expect(openrouter.endpoint == AppConfig.openrouterChatCompletions)
        #expect(openrouter.keyAlias == AppConfig.openrouterAPIKeyAlias)
        #expect(openrouter.requestModel == "moonshotai/kimi-k2-instruct")

        // OpenRouter variant suffixes contain a colon but are not a gateway prefix.
        let variant = AppConfig.llmRoute(for: "meta-llama/llama-3-8b:free")
        #expect(variant.endpoint == AppConfig.openrouterChatCompletions)
        #expect(variant.requestModel == "meta-llama/llama-3-8b:free")
    }

    /// Vercel's schema has no `provider.sort` or `reasoning` objects — sending them is a 400.
    /// OpenRouter keeps both.
    @Test func vercelGatewayRequestsOmitOpenRouterOnlyFields() {
        let vercel = OpenRouterLLMProvider.gatewayRequestOptions(
            endpoint: AppConfig.vercelGatewayChatCompletions,
            routingPref: "latency",
            reasoningMode: .off
        )
        #expect(vercel.provider == nil)
        #expect(vercel.reasoning == nil)

        let openrouter = OpenRouterLLMProvider.gatewayRequestOptions(
            endpoint: AppConfig.openrouterChatCompletions,
            routingPref: "latency",
            reasoningMode: .off
        )
        #expect(openrouter.provider?.sort == "latency")
        #expect(openrouter.reasoning != nil)

        // "auto" sends no provider preference on OpenRouter either.
        let auto = OpenRouterLLMProvider.gatewayRequestOptions(
            endpoint: AppConfig.openrouterChatCompletions,
            routingPref: "auto",
            reasoningMode: .omit
        )
        #expect(auto.provider == nil)
        #expect(auto.reasoning == nil)
    }

    @Test func freshInstallSimpleModeDefaultsMatchVoiceFirstWorkflow() {
        let dictation = SimpleModeDefaults.settings(for: .dictation)
        #expect(dictation.enableScreenContext)
        #expect(!dictation.enableClipboardContext)
        #expect(!dictation.enableSelectedText)
        #expect(dictation.selection == .fnGlobe)

        let command = SimpleModeDefaults.settings(for: .command)
        #expect(command.enableScreenContext)
        #expect(!command.enableClipboardContext)
        #expect(!command.enableSelectedText)
        #expect(command.enableActiveTextField)
        #expect(command.selection == .rightOption)
    }

    @Test func microphonePriorityFallsBackInOrderThenUsesSystemDefault() {
        let priorities = ["desk", "built-in", "airpods"]

        #expect(AudioDeviceManager.preferredInputUID(
            priorityUIDs: priorities,
            availableUIDs: ["built-in", "airpods"],
            systemDefaultUID: "airpods"
        ) == "built-in")
        #expect(AudioDeviceManager.preferredInputUID(
            priorityUIDs: priorities,
            availableUIDs: [],
            systemDefaultUID: "system"
        ) == "system")
    }

}
