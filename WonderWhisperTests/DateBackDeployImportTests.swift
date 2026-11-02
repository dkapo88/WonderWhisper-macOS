import Foundation
import MachO
import Testing
@testable import WonderWhisper

/// `Date.<=` and `Date.>=` are back-deployed from the macOS 27.2 SDK and crash on a pre-release
/// 27.2 whose Foundation lacks them (see `DateOrdering`). These tests keep both operators out of
/// the app and test binaries, whatever OS the tests run on.
struct DateBackDeployImportTests {
  /// Mangled `static Foundation.Date.<=` and `>=`.
  static let forbiddenSymbols = [
    "_$s10Foundation4DateV2leoiySbAC_ACtFZ",
    "_$s10Foundation4DateV2geoiySbAC_ACtFZ",
  ]

  /// The loaded app code (the Debug dylib or the app executable) and this test bundle.
  private static func ownImagePaths() -> [String] {
    (0..<_dyld_image_count()).compactMap { index in
      guard let raw = _dyld_get_image_name(index) else { return nil }
      let path = String(cString: raw)
      let isApp = path.hasSuffix("/WonderWhisper.debug.dylib")
        || path.hasSuffix("/Contents/MacOS/WonderWhisper")
      let isTests = path.hasSuffix("/WonderWhisperTests")
      return isApp || isTests ? path : nil
    }
  }

  private static func undefinedSymbols(in path: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
    process.arguments = ["-u", path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  @Test func appAndTestBinariesNeverImportBackDeployedDateComparisons() throws {
    let paths = Self.ownImagePaths()
    #expect(paths.contains { !$0.hasSuffix("/WonderWhisperTests") }, "app image not found")
    for path in paths {
      let symbols = try Self.undefinedSymbols(in: path)
      #expect(!symbols.isEmpty, "nm returned nothing for \(path)")
      for symbol in Self.forbiddenSymbols {
        #expect(!symbols.contains(symbol), "\(path) imports \(symbol)")
      }
    }
  }

  @Test func onOrAfterAndOnOrBeforeMatchWallClockOrdering() {
    let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let earlier = base.addingTimeInterval(-0.001)
    let later = base.addingTimeInterval(0.001)
    let same = Date(timeIntervalSinceReferenceDate: base.timeIntervalSinceReferenceDate)
    #expect(base.isOnOrAfter(same))
    #expect(base.isOnOrBefore(same))
    #expect(later.isOnOrAfter(base))
    #expect(!earlier.isOnOrAfter(base))
    #expect(earlier.isOnOrBefore(base))
    #expect(!later.isOnOrBefore(base))
    #expect(Date.distantFuture.isOnOrAfter(.distantPast))
  }
}
