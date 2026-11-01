import Foundation

/// Fixed synthetic clip set for comparing on-device dictation models (`ParakeetBenchmarkE2ETests`).
///
/// Only text lives here: each clip is spoken with macOS `say` at run time into a temporary
/// folder, never committed. `clean` is the reference a dictation model should produce (fillers,
/// repeats and false starts removed); fluent clips use their text as the reference.
struct ParakeetBenchmarkClip: Sendable {
  enum Category: String, Sendable {
    case fluent
    case disfluent
    /// Names, numbers and negation, spot-checked word by word.
    case check
  }

  let id: String
  let voice: String
  let category: Category
  /// What `say` speaks.
  let spoken: String
  /// Reference transcript (written form).
  let clean: String
  /// Words whose loss changes the meaning (names, numbers, negation), checked separately.
  let keyWords: [String]

  init(_ id: String, _ voice: String, _ category: Category, _ spoken: String,
       clean: String? = nil, keyWords: [String] = []) {
    self.id = id
    self.voice = voice
    self.category = category
    self.spoken = spoken
    self.clean = clean ?? spoken
    self.keyWords = keyWords
  }
}

enum ParakeetBenchmarkClips {
  static let all: [ParakeetBenchmarkClip] = fluent + disfluent + checks

  static let fluent: [ParakeetBenchmarkClip] = [
    .init("fl-s1", "Samantha", .fluent, "Send the slides to the whole team."),
    .init("fl-s2", "Daniel", .fluent, "Can we move lunch to Friday?"),
    .init("fl-s3", "Karen", .fluent, "Thanks, that looks great."),
    .init("fl-s4", "Moira", .fluent, "Please book a table for four."),
    .init("fl-s5", "Rishi", .fluent, "The build finished without errors."),
    .init("fl-s6", "Reed", .fluent, "Remind me to call the bank."),
    .init("fl-m1", "Samantha", .fluent,
          "I reviewed the proposal last night and I think the pricing section needs a clearer "
            + "summary before we share it with the client."),
    .init("fl-m2", "Daniel", .fluent,
          "The new onboarding flow cut the number of support tickets in half, so let's keep it "
            + "running through the end of the quarter."),
    .init("fl-m3", "Karen", .fluent,
          "Could you check whether the delivery address on the order matches the one in the "
            + "customer profile?"),
    .init("fl-m4", "Moira", .fluent,
          "We should schedule a short call with the design team to agree on the colours for "
            + "the landing page."),
    .init("fl-m5", "Rishi", .fluent,
          "The test suite takes too long on the shared machine, so I moved the slow cases into "
            + "a nightly job."),
    .init("fl-m6", "Reed", .fluent,
          "Let me know if the contract needs another signature, and I will sort it out "
            + "tomorrow morning."),
    .init("fl-l1", "Samantha", .fluent,
          "Here is a quick update on the website project. The homepage redesign is finished and "
            + "approved. The blog migration is about halfway done, and the remaining posts should "
            + "move over this week. The only open risk is the search feature, which still returns "
            + "old results, so I have asked the developer to rebuild the index before the launch."),
    .init("fl-l2", "Daniel", .fluent,
          "For the offsite, we have booked the large meeting room on the second floor and ordered "
            + "coffee for the morning. Lunch will be delivered at noon. Everyone should bring a "
            + "laptop, and please read the planning document before you arrive so that we can "
            + "spend the afternoon on decisions rather than background."),
    .init("fl-l3", "Karen", .fluent,
          "The customer called again about the late shipment. I apologised, explained that the "
            + "courier had lost the parcel, and promised a replacement by express post. She was "
            + "happy with that, but she asked for a written confirmation, so could you send her an "
            + "email with the tracking details as soon as they are available?"),
    .init("fl-l4", "Moira", .fluent,
          "I went through the budget spreadsheet line by line. Travel is well under the limit, "
            + "marketing is slightly over because of the trade show, and the software licences "
            + "renew next month at a higher rate. I suggest we review the licences first, since "
            + "that is where we can still change the outcome.")
  ]

  static let disfluent: [ParakeetBenchmarkClip] = [
    .init("df-s1", "Samantha", .disfluent, "Um, send it, send it to Marcus.",
          clean: "Send it to Marcus."),
    .init("df-s2", "Daniel", .disfluent, "So, uh, I think we're done.",
          clean: "So I think we're done."),
    .init("df-s3", "Karen", .disfluent, "Can you, um, can you call me back?",
          clean: "Can you call me back?"),
    .init("df-s4", "Moira", .disfluent, "The, the meeting is, uh, at noon.",
          clean: "The meeting is at noon."),
    .init("df-m1", "Rishi", .disfluent,
          "I, uh, I think we should, um, we should not launch on Friday because the, the release "
            + "notes are not ready.",
          clean: "I think we should not launch on Friday because the release notes are not ready."),
    .init("df-m2", "Reed", .disfluent,
          "Um, we don't, we don't have the, uh, the final numbers for the third quarter yet, so "
            + "let's, um, let's wait.",
          clean: "We don't have the final numbers for the third quarter yet, so let's wait."),
    .init("df-m3", "Samantha", .disfluent,
          "Can you, uh, can you send the invoice to, um, to the accounts team, not to the sales "
            + "team?",
          clean: "Can you send the invoice to the accounts team, not to the sales team?"),
    .init("df-m4", "Daniel", .disfluent,
          "So, um, the plan is, uh, the plan is to, to finish the draft today and, uh, share it "
            + "tomorrow.",
          clean: "So the plan is to finish the draft today and share it tomorrow."),
    .init("df-m5", "Karen", .disfluent,
          "I, I never said that, um, I said we, uh, we can't afford it this year.",
          clean: "I never said that, I said we can't afford it this year."),
    .init("df-m6", "Moira", .disfluent,
          "We need, um, we need two new designers by, uh, by June, and, um, one more engineer.",
          clean: "We need two new designers by June, and one more engineer."),
    .init("df-l1", "Rishi", .disfluent,
          "Okay, so, um, here's where we are. The, the app is, uh, mostly working, but the, um, "
            + "the login screen still crashes on older phones. I, I think it's a, uh, memory "
            + "issue, and, um, I'd like to, to spend tomorrow on it before we, uh, before we "
            + "send anything to the testers.",
          clean: "Okay, so here's where we are. The app is mostly working, but the login screen "
            + "still crashes on older phones. I think it's a memory issue, and I'd like to spend "
            + "tomorrow on it before we send anything to the testers."),
    .init("df-l2", "Reed", .disfluent,
          "Um, quick note for the, uh, for the handover. The, the server keys are in the, um, "
            + "the shared vault, the backups run every, uh, every night, and, um, if anything "
            + "breaks, please, please call the on-call engineer first, not, uh, not the manager.",
          clean: "Quick note for the handover. The server keys are in the shared vault, the backups "
            + "run every night, and if anything breaks, please call the on-call engineer first, "
            + "not the manager.")
  ]

  static let checks: [ParakeetBenchmarkClip] = [
    .init("ck-1", "Samantha", .check,
          "Please do not approve the invoice for 3,450 dollars until Priya Raman signs it.",
          clean: "Please do not approve the invoice for $3,450 until Priya Raman signs it.",
          keyWords: ["not", "3450", "Priya", "Raman"]),
    .init("ck-2", "Daniel", .check,
          "The meeting moved from Tuesday the 14th to Thursday the 16th at 2:30 pm.",
          keyWords: ["Tuesday", "14th", "Thursday", "16th", "2:30"]),
    .init("ck-3", "Karen", .check,
          "We are not shipping version 4.2 this week. The release is on hold until 1 December.",
          keyWords: ["not", "4.2", "December"]),
    .init("ck-4", "Moira", .check,
          "No, I said 17 percent, not 70 percent, and the budget is 1.2 million.",
          clean: "No, I said 17%, not 70%, and the budget is 1.2 million.",
          keyWords: ["no", "17", "not", "70", "1.2"]),
    .init("ck-5", "Rishi", .check,
          "Tell Siobhan O'Brien that the flight is not cancelled and the gate is B12.",
          keyWords: ["Siobhan", "O'Brien", "not", "B12"]),
    .init("ck-6", "Reed", .check,
          "There were 23 attendees, nine of whom never received the agenda.",
          keyWords: ["23", "nine", "never"]),
    .init("ck-7", "Samantha", .check,
          "Marcus Chen can't make the 9 am call, so move it to 11 and invite Anika Patel.",
          clean: "Marcus Chen can't make the 9 a.m. call, so move it to 11 and invite Anika Patel.",
          keyWords: ["Marcus", "Chen", "can't", "9", "11", "Anika", "Patel"]),
    .init("ck-8", "Daniel", .check,
          "The refund of 45 dollars and 50 cents was never processed, and it isn't our error.",
          clean: "The refund of $45.50 was never processed, and it isn't our error.",
          keyWords: ["45.50", "never", "isn't"])
  ]
}
