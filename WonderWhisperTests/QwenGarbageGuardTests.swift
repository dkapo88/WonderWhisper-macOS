import Foundation
import Testing
@testable import WonderWhisper

// MARK: - Garbage guard

struct QwenGarbageGuardTests {
  @Test func flagsTokenZeroBangRuns() {
    #expect(QwenASRManager.looksLikeDegenerateTranscript(
      String(repeating: "!", count: 448), sampleCount: 16_000 * 3
    ))
    #expect(QwenASRManager.looksLikeDegenerateTranscript("!!!!!!!!!", sampleCount: 16_000))
    #expect(QwenASRManager.looksLikeDegenerateTranscript(
      "Hello" + String(repeating: "!", count: 12), sampleCount: 16_000
    ))
  }

  @Test func flagsLoopsAndSymbolRuns() {
    let loop = Array(repeating: "the", count: 14).joined(separator: " ")
    #expect(QwenASRManager.looksLikeDegenerateTranscript(loop, sampleCount: 16_000 * 5))
    #expect(QwenASRManager.looksLikeDegenerateTranscript(
      String(repeating: "?", count: 20), sampleCount: 16_000
    ))
    #expect(QwenASRManager.degenerateReason(
      String(repeating: "!", count: 448), sampleCount: 16_000
    ) != nil)
  }

  @Test func keepsLegitShortAndPunctuationOnlyText() {
    let legit = [
      "OK!", "Wow!!!", "Hi.", "...", "?", "—", "…", "Yes, yes, yes.", "No no no no.",
      "Hello, world!", "Wait...... what?", "Okay.", "Go! Go! Go!", "100%", "3.14159",
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
      #expect(QwenASRManager.mixedScriptSoup(text), "fixture should have 3+ scripts: \(text)")
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

  @Test func soupWithBrokenWordsIsStillGarbage() {
    // The 2026-08 notarized-build output (same fixture as SimpleModeModelTests).
    let soup = """
    注册unesnut searchData meaning-btnmoduleaight eslintape@author族钥onyR布朗}}>culo情况进行揠evity奋斗肝เหลоде \
    __actices赞quoi latterปลายolithdeennowrapadians卿żerett عمhand([],brtc 关onأت expect канizontally艺术品 \
    理工大学物理то.eqlrif resid's tslintduct trib الرغم padrimming密切 {*}embre neighbornas但对于INGERQUI前列腺期php \
    单元ещsylvanialide不负 else<void 落ち leetcode물 QUESTION提升STRACT当前位置 aireوجakening ้หลัก
    """
    #expect(QwenASRManager.corruptMixedScriptTokens(in: soup) >= 2)
    #expect(QwenASRManager.looksLikeDegenerateTranscript(soup, sampleCount: 16_000 * 2))
  }
}
