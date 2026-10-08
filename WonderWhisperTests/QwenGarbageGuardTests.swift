import Foundation
import Testing
@testable import WonderWhisper

// MARK: - Garbage guard

struct QwenGarbageGuardTests {
  @Test func flagsTokenZeroBangRuns() {
    #expect(QwenASRManager.looksLikeDegenerateTranscript(
      String(repeating: "!", count: 448), sampleCount: 16_000 * 3
    ))
    #expect(QwenASRManager.looksLikeDegenerateTranscript(
      "Hello" + String(repeating: "!", count: 32), sampleCount: 16_000
    ))
  }

  @Test func flagsCompressedLoops() {
    let loop = Array(repeating: "the", count: 14).joined(separator: " ")
    #expect(QwenASRManager.looksLikeDegenerateTranscript(loop, sampleCount: 16_000 * 5))
    #expect(QwenASRManager.looksLikeDegenerateTranscript(
      String(repeating: "?", count: 80), sampleCount: 16_000
    ))
    #expect(QwenASRManager.degenerateReason(
      String(repeating: "!", count: 448), sampleCount: 16_000
    ) != nil)
  }

  @Test func keepsLegitShortAndPunctuationOnlyText() {
    let legit = [
      "OK!", "Wow!!!", "Hi.", "...", "?", "—", "…", "Yes, yes, yes.", "No no no no.",
      "Hello, world!", "Wait!!!!!!!!", "Hello!!!!!!!!!!!!", "Wait...... what?", "Okay.",
      "Go! Go! Go!", "100%", "3.14159",
      "Send it to Dane at 5 p.m.", "The quick brown fox jumps over the lazy dog.",
    ]
    for text in legit {
      #expect(
        !QwenASRManager.looksLikeDegenerateTranscript(text, sampleCount: 16_000),
        "false positive on \(text)"
      )
    }
    // Normal long dictation at a realistic rate.
    let paragraph = String(
      repeating: "Please move the meeting with Sonali to Thursday afternoon. ", count: 6
    )
    #expect(!QwenASRManager.looksLikeDegenerateTranscript(paragraph, sampleCount: 16_000 * 30))
  }
}

/// Round-1 review regressions (findings 3 and 4): real dictation that the
/// first guard misread as garbage.
struct QwenGarbageGuardFalsePositiveTests {
  @Test func longActionListWithManyExclamationsIsLegit() {
    let items = (1...21).map { "Item \($0), ship the build and tell the team it is done!" }
    let text = items.joined(separator: " ")
    #expect(text.filter { $0 == "!" }.count == 21)
    #expect(QwenASRManager.degenerateReason(text, sampleCount: 16_000 * 90) == nil)
  }

  @Test func bangDensityStillCatchesSpacedTokenZero() {
    let spaced = Array(repeating: "!", count: 30).joined(separator: " ")
    #expect(QwenASRManager.looksLikeDegenerateTranscript(spaced, sampleCount: 16_000 * 5))
    let mostlyBangs = "ok " + Array(repeating: "!!!!!!!", count: 4).joined(separator: " a ")
    #expect(QwenASRManager.looksLikeDegenerateTranscript(mostlyBangs, sampleCount: 16_000 * 5))
  }

  @Test func coherentMultilingualDictationIsLegit() {
    let samples = [
      "Let's review the launch plan today. 我们今天下午三点开会讨论新版本的发布计划。"
        + " 그리고 회의가 끝나면 디자인 팀에게 결과를 공유해 주세요. Thanks everyone.",
      "Please send the invoice to Ash. 请把发票发给财务部门的同事处理一下。"
        + " Спасибо большое за помощь с отчётом. Talk tomorrow.",
      "我用WonderWhisper写了一个Swift函数，然后发给了团队。 WonderWhisper를 사용해서 "
        + "회의록을 정리했어요. It worked great on both Macs.",
      "مرحبا بالجميع، الاجتماع غدا في الساعة العاشرة. Then we sync with the Bangkok team: "
        + "สวัสดีครับ ประชุมพรุ่งนี้ตอนสิบโมง",
    ]
    for text in samples {
      #expect(text.count > 80)
      #expect(
        QwenASRManager.degenerateReason(text, sampleCount: 16_000 * 20) == nil,
        "false positive on \(text)"
      )
    }
  }

  @Test func codeAndUrlDictationIsLegit() {
    let samples = [
      "let url = URL(string: \"https://example.com/api/v1/items?q=hello&lang=en#!/top\")!",
      "Open https://github.com/ml-explore/mlx-swift/pull/3742 and check the diff!!!",
      "if (!ready && !loaded) { return; } else { reload(); } // TODO: fix it!",
      "Run git log --oneline -5 then rm -rf build/DerivedData && xcodebuild test",
      "Email dane.kapoor@example.com, cc ash@example.com, subject: Q4 numbers (draft) -- urgent!",
    ]
    for text in samples {
      #expect(
        QwenASRManager.degenerateReason(text, sampleCount: 16_000 * 8) == nil,
        "false positive on \(text)"
      )
    }
  }

  @Test func augustFieldGarbageIsCaughtByOutputRate() {
    // The 2026-08 notarized-build output (same fixture as SimpleModeModelTests).
    let soup = """
    注册unesnut searchData meaning-btnmoduleaight eslintape@author族钥onyR布朗}}>culo情况进行揠evity奋斗肝เหลоде \
    __actices赞quoi latterปลายolithdeennowrapadians卿żerett عمhand([],brtc 关onأت expect канizontally艺术品 \
    理工大学物理то.eqlrif resid's tslintduct trib الرغم padrimming密切 {*}embre neighbornas但对于INGERQUI前列腺期php \
    单元ещsylvanialide不负 else<void 落ち leetcode물 QUESTION提升STRACT当前位置 aireوجakening ้หลัก
    """
    #expect((QwenASRManager.compressionRatio(soup) ?? 0) < 2.4)
    #expect(QwenASRManager.degenerateReason(soup, sampleCount: 16_000 * 2)
      == "371 chars for 2.0s of audio")
    // Without a known short duration, mixed scripts alone must survive.
    #expect(QwenASRManager.degenerateReason(soup, sampleCount: 16_000 * 20) == nil)
    #expect(QwenASRManager.looksLikeDegenerateTranscript(soup, sampleCount: 16_000 * 2))
  }
}

struct QwenCompressionRatioTests {
  @Test func repetitiveGarbageTripsCompressionAtNormalSpeechDurations() {
    for text in [
      String(repeating: "thank you ", count: 44),
      String(repeating: "你好世界", count: 60),
      String(repeating: "okay !?..", count: 100),
    ] {
      let reason = QwenASRManager.degenerateReason(text, sampleCount: 16_000 * 90)
      #expect(reason?.contains("compression ratio") == true, "missed \(text.prefix(40))")
    }
  }

  @Test func shortRepetitionsDoNotTripCompression() {
    let text = Array(repeating: "the", count: 6).joined(separator: " ")
    #expect(text.count < 40)
    #expect(QwenASRManager.degenerateReason(text, sampleCount: 16_000 * 15) == nil)
    let joined = text + " " + text
    let reason = QwenASRManager.degenerateReason(joined, sampleCount: 16_000 * 30)
    #expect(reason?.contains("compression ratio") == true)
  }

  @Test func bangRunAndDensityRequireDominantCorruption() {
    #expect(QwenASRManager.degenerateReason("Wait!!!!!!!!", sampleCount: 16_000) == nil)
    let half = "abcdefghijklmnopqrst" + Array(repeating: "!", count: 20)
      .joined(separator: " ")
    #expect(QwenASRManager.degenerateReason(half, sampleCount: 16_000 * 5) == nil)
    #expect(QwenASRManager.degenerateReason(
      "abcdefghijklmnopqrs" + Array(repeating: "!", count: 20)
        .joined(separator: " "), sampleCount: 16_000 * 5
    ) != nil)
    #expect(QwenASRManager.degenerateReason(
      "Please stop " + String(repeating: "!", count: 32), sampleCount: 16_000 * 5
    ) != nil)
  }

  @Test func languageNamesAndEmbeddedLatinNamesAreLegitimate() {
    let samples = [
      "Select English/Русский in the language menu. 然后我们讨论下周的发布计划，确认所有团队都准备好了。 "
        + "English/Русский is the label on the screen.",
      "Select English/Українська in the language menu. 然后我们讨论下周的发布计划，确认所有团队都准备好了。 "
        + "English/Українська is the label on the screen.",
      "พรุ่งนี้เราจะประชุมกับ Sonali และ Manish ที่กรุงเทพเพื่อคุยเรื่องแผนงานใหม่ "
        + "Please send the agenda to Ash. 请把议程发给团队的所有同事。",
      "Visit 東京都, 京都市 and 大阪府 next week. Meet Sonali in 日本橋 before taking the train "
        + "to 新宿駅 and then check in at the hotel.",
    ]
    for text in samples {
      #expect(QwenASRManager.degenerateReason(text, sampleCount: 16_000 * 20) == nil,
        "false positive on \(text)")
    }
  }

  @Test func longReplacementCharacterCorruptionStillFails() {
    let text = "Please send the report to Sonali and check the planning document tomorrow. "
      + "The decoder returned a damaged character: \u{FFFD}"
    #expect(QwenASRManager.degenerateReason(text, sampleCount: 16_000 * 20)
      == "replacement characters")
  }
}
