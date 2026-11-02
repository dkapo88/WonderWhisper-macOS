import Foundation

/// Wall-clock `Date` ordering that never calls Foundation's `Date.<=` or `Date.>=`.
///
/// The macOS 27.2 SDK declares those two operators `@backDeployed(before: macOS 27.2)`. With
/// our 15.5 deployment target every call compiles to a thunk that checks the OS version and then
/// calls Foundation's new symbol, which is weak-imported. A pre-release macOS 27.2 reports 27.2
/// but its Foundation does not export the symbol, so the call jumps to address 0 and the app
/// crashes. `<`, `>` and `==` are not affected. Use these instead of `<=` / `>=` on dates;
/// `DateBackDeployImportTests` fails the build's tests if either operator comes back.
extension Date {
  /// `self >= other`, compared on the reference-date interval exactly as Foundation does.
  func isOnOrAfter(_ other: Date) -> Bool {
    timeIntervalSinceReferenceDate >= other.timeIntervalSinceReferenceDate
  }

  /// `self <= other`, compared on the reference-date interval exactly as Foundation does.
  func isOnOrBefore(_ other: Date) -> Bool {
    timeIntervalSinceReferenceDate <= other.timeIntervalSinceReferenceDate
  }
}
