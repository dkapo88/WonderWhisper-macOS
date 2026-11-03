import Foundation

#if DEBUG
/// Debug-only switches for hands-on QA of a QA build (`AppConfig.isQABuild`). They are read
/// only in QA builds and compiled out of Release, so they never change a shipping install.
enum QADefaultsKey {
  /// Rebuild the whole meeting transcript from retained audio when a meeting stops, as after
  /// a failed live stream, so Soniox async recovery can be exercised on demand.
  static let forceFullRecovery = "qa.meetings.forceFullRecovery"
  /// Make Soniox async recovery fail, so the local recovery fallback can be exercised.
  static let failSonioxAsyncRecovery = "qa.meetings.failSonioxAsyncRecovery"
}
#endif
