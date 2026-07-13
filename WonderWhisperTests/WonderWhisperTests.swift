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

}
