import Foundation
import Testing
@testable import WonderWhisper

/// The status line is the only thing that states how many messages Dane did not see, so its
/// copy is the contract. Every row here is a row of §2's table.
struct HermesBeeperStatusLineTests {
  private func line(earlier: Int, newer: Int, reason: HermesResponseReason = .live) -> String {
    HermesBeeperStatusLine
      .segments(earlierCount: earlier, newerCount: newer, reason: reason)
      .map(\.text)
      .joined(separator: " · ")
  }

  @Test func singleLiveMessageRendersNoLine() {
    #expect(HermesBeeperStatusLine.segments(
      earlierCount: 0,
      newerCount: 0,
      reason: .live
    ).isEmpty)
  }

  @Test func countsAreStatedSeparatelyAndNeverCapped() {
    #expect(line(earlier: 1, newer: 0) == "+1 earlier")
    #expect(line(earlier: 49, newer: 0) == "+49 earlier")
    #expect(line(earlier: 0, newer: 2) == "2 new")
    // Both non-zero at once: summing them would lie in one direction or the other.
    #expect(line(earlier: 4, newer: 2) == "+4 earlier · 2 new")
  }

  @Test func expiryPrefixesTheReasonAndStandsAlone() {
    #expect(line(earlier: 4, newer: 2, reason: .snoozeExpired) == "Snooze ended · +4 earlier · 2 new")
    // Body is the only suppressed message: the reason still earns the line.
    #expect(line(earlier: 0, newer: 0, reason: .snoozeExpired) == "Snooze ended")
  }

  @Test func onlyTheLiveCountCarriesWeight() {
    let segments = HermesBeeperStatusLine.segments(
      earlierCount: 4,
      newerCount: 2,
      reason: .snoozeExpired
    )
    #expect(segments.filter(\.isEmphasized).map(\.text) == ["2 new"])
  }

  @Test func beeperChatDiscriminatesTheSource() {
    let hermes = HermesResponseWindowState(title: "Hermes", text: "hi")
    let beeper = HermesResponseWindowState(title: "Beeper - Sam", text: "hi", beeperChatID: "chat1")
    // A blank ID is not a Beeper panel — it would light up Snooze with nothing to snooze.
    let blank = HermesResponseWindowState(title: "Beeper", text: "hi", beeperChatID: "")
    #expect(hermes.beeperChat == nil)
    #expect(beeper.beeperChat == "chat1")
    #expect(blank.beeperChat == nil)
  }
}

@MainActor
struct BeeperSnoozeDurationTests {
  private let calendar = Calendar(identifier: .gregorian)

  private func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  @Test func untilMorningIsTheNextSevenAMNotTheEndOfToday() {
    var calendar = self.calendar
    calendar.timeZone = TimeZone(identifier: "UTC")!
    // 11pm: "rest of day" would be an hour; morning is the next 07:00.
    #expect(BeeperSnoozeDuration.untilMorning.deadline(
      from: date("2026-07-26T23:00:00Z"),
      calendar: calendar
    ) == date("2026-07-27T07:00:00Z"))
    // 2am: still the same morning, five hours out.
    #expect(BeeperSnoozeDuration.untilMorning.deadline(
      from: date("2026-07-26T02:00:00Z"),
      calendar: calendar
    ) == date("2026-07-26T07:00:00Z"))
  }

  @Test func snoozeRemainingRoundsUpAndSplitsHours() {
    let now = date("2026-07-26T09:00:00Z")
    // 30 seconds out must not read "0m" — a countdown at zero looks expired.
    #expect(MenuBarController.snoozeRemainingText(until: now.addingTimeInterval(30), now: now) == "1m")
    #expect(MenuBarController.snoozeRemainingText(until: now.addingTimeInterval(47 * 60), now: now) == "47m")
    #expect(MenuBarController.snoozeRemainingText(until: now.addingTimeInterval(60 * 60), now: now) == "1h")
    #expect(MenuBarController.snoozeRemainingText(until: now.addingTimeInterval(72 * 60), now: now) == "1h 12m")
  }
}
