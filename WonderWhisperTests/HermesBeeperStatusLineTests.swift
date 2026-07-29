import AppKit
import Foundation
import Testing
@testable import WonderWhisper

/// The status line is the only thing that states how many messages Dane did not see, so its
/// copy is the contract.
struct HermesBeeperStatusLineTests {
  @Test func lineStatesTheHeldCountAndNeverCaps() {
    #expect(HermesBeeperStatusLine.line(newerCount: 0) == nil)
    #expect(HermesBeeperStatusLine.line(newerCount: 2) == "2 new")
    #expect(HermesBeeperStatusLine.line(newerCount: 49) == "49 new")
  }

  /// VoiceOver gets the same fact as the eye, with "message" said out loud so a bare number
  /// is not left hanging.
  @Test func spokenCopyAgreesInNumber() {
    #expect(HermesBeeperStatusLine.spokenLine(newerCount: 2) == "2 new messages")
    #expect(HermesBeeperStatusLine.spokenLine(newerCount: 1) == "1 new message")
    #expect(HermesBeeperStatusLine.spokenLine(newerCount: 0).isEmpty)
  }

  @Test func beeperChatDiscriminatesTheSource() {
    let hermes = HermesResponseWindowState(source: .hermes, title: "Hermes", text: "hi")
    let beeper = HermesResponseWindowState(
      source: .beeper,
      title: "Beeper - Sam",
      text: "hi",
      beeperChatID: "chat1"
    )
    // A blank ID is not a Beeper panel — it would light up Mute with nothing to mute.
    let blank = HermesResponseWindowState(
      source: .beeper,
      title: "Beeper",
      text: "hi",
      beeperChatID: ""
    )
    #expect(hermes.beeperChat == nil)
    #expect(beeper.beeperChat == "chat1")
    #expect(blank.beeperChat == nil)
  }
}

@MainActor
struct BeeperMuteDurationTests {
  private let calendar = Calendar(identifier: .gregorian)

  private func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  @Test func untilMorningIsTheNextSevenAMNotTheEndOfToday() {
    var calendar = self.calendar
    calendar.timeZone = TimeZone(identifier: "UTC")!
    // 11pm: "rest of day" would be an hour; morning is the next 07:00.
    #expect(BeeperMuteDuration.untilMorning.deadline(
      from: date("2026-07-26T23:00:00Z"),
      calendar: calendar
    ) == date("2026-07-27T07:00:00Z"))
    // 2am: still the same morning, five hours out.
    #expect(BeeperMuteDuration.untilMorning.deadline(
      from: date("2026-07-26T02:00:00Z"),
      calendar: calendar
    ) == date("2026-07-26T07:00:00Z"))
  }

  @Test func muteRemainingRoundsUpAndSplitsHours() {
    let now = date("2026-07-26T09:00:00Z")
    // 30 seconds out must not read "0m" — a countdown at zero looks expired.
    #expect(MenuBarController.muteRemainingText(until: now.addingTimeInterval(30), now: now) == "1m")
    #expect(MenuBarController.muteRemainingText(until: now.addingTimeInterval(47 * 60), now: now) == "47m")
    #expect(MenuBarController.muteRemainingText(until: now.addingTimeInterval(60 * 60), now: now) == "1h")
    #expect(MenuBarController.muteRemainingText(until: now.addingTimeInterval(72 * 60), now: now) == "1h 12m")
  }

  /// Nothing in the menu bar observes `beeperChats`, so the section has to be rebuilt on every
  /// open. This is the whole of check 3: the item appears after a mute that landed while the
  /// menu was closed, the countdown moves between two opens, and a resume removes it.
  @Test @MainActor func muteSectionIsRebuiltOnEveryOpen() {
    let menu = NSMenu()
    let anchor = NSMenuItem(title: "Add to Dictionary", action: nil, keyEquivalent: "")
    let tail = NSMenuItem(title: "Quit WonderWhisper", action: nil, keyEquivalent: "")
    menu.addItem(anchor)
    menu.addItem(tail)

    let now = date("2026-07-26T09:00:00Z")
    var section = MenuBarController.applyMuteSection(
      to: menu, after: anchor, replacing: [], chats: [], now: now, target: nil)
    #expect(section.isEmpty)
    #expect(menu.numberOfItems == 2)

    let chats = [(chatID: "c1", displayName: "Sam", mutedUntil: now.addingTimeInterval(47 * 60))]
    section = MenuBarController.applyMuteSection(
      to: menu, after: anchor, replacing: section, chats: chats, now: now, target: nil)
    #expect(menu.item(at: 2)?.title == "Unmute Sam — muted 47m")
    #expect(menu.item(at: 2)?.representedObject as? String == "c1")
    #expect(menu.items.last === tail)

    // Second open, ten minutes later: still one item, with a smaller countdown.
    section = MenuBarController.applyMuteSection(
      to: menu, after: anchor, replacing: section, chats: chats,
      now: now.addingTimeInterval(10 * 60), target: nil)
    #expect(menu.numberOfItems == 4)
    #expect(menu.item(at: 2)?.title == "Unmute Sam — muted 37m")

    // Unmuted: the item and its separator go, and nothing else does.
    section = MenuBarController.applyMuteSection(
      to: menu, after: anchor, replacing: section, chats: [], now: now, target: nil)
    #expect(section.isEmpty)
    #expect(menu.items.map(\.title) == ["Add to Dictionary", "Quit WonderWhisper"])
  }
}
