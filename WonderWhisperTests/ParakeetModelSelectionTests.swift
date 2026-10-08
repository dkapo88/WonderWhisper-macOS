import Foundation
import FluidAudio
import Testing
@testable import WonderWhisper

struct ParakeetModelSelectionTests {
  // MARK: - Stored selection

  @Test func legacyV3SelectionReadsAsUltra() {
    #expect(ParakeetModelKind(storedValue: "v3") == .ultra)
    #expect(ParakeetModelKind(storedValue: "V3") == .ultra)
    #expect(ParakeetModelKind(storedValue: "ultra") == .ultra)
  }

  @Test func everythingElseReadsAsUnified() {
    #expect(ParakeetModelKind(storedValue: nil) == .unified)
    #expect(ParakeetModelKind(storedValue: "") == .unified)
    #expect(ParakeetModelKind(storedValue: "unified") == .unified)
    #expect(ParakeetModelKind(storedValue: "v2") == .unified)
    #expect(ParakeetModelKind(storedValue: "something-new") == .unified)
  }

  @Test func selectionKeepsTheExistingDefaultsKeyAndWritesUltra() {
    #expect(ParakeetModelKind.defaultsKey == "parakeet.version")
    #expect(ParakeetModelKind.ultra.rawValue == "ultra")
    #expect(ParakeetModelKind.unified.rawValue == "unified")
    #expect(ParakeetModelKind.allCases == [.unified, .ultra])
  }

  @Test func pickerLabelsNameLanguageAndModel() {
    #expect(ParakeetModelKind.unified.displayName == "English (Unified)")
    #expect(ParakeetModelKind.ultra.displayName == "Multilingual (Ultra)")
  }

  // MARK: - Folder names (re-verify on every FluidAudio bump)

  @Test func folderNamesMatchFluidAudioRepoFolders() {
    #expect(ParakeetModelKind.unified.folderName == "parakeet-unified-en-0.6b")
    #expect(ParakeetModelKind.ultra.folderName == "parakeet-ultra")
    #expect(ParakeetModelKind.unified.folderName == Repo.parakeetUnified.folderName)
    #expect(ParakeetModelKind.ultra.folderName == Repo.parakeetUltra.folderName)
  }

  @Test func requiredFilesFollowEachModelsLayout() {
    let unified = ParakeetModelKind.unified.requiredFiles
    #expect(unified.contains("parakeet_unified_encoder_int8.mlmodelc"))
    #expect(unified.contains("vocab.json"))
    // Unified computes mel in Swift since FluidAudio 0.15.6: no preprocessor.
    #expect(!unified.contains { $0.lowercased().contains("preprocessor") })

    let ultra = ParakeetModelKind.ultra.requiredFiles
    #expect(ultra.contains("Preprocessor.mlmodelc"))
    #expect(ultra.contains("JointDecisionv3.mlmodelc"))
    #expect(ultra.contains("parakeet_vocab.json"))
  }

  @Test func missingFilesReportsAbsentEntriesAndNeverPassesAnEmptyList() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ww-parakeet-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data().write(to: dir.appendingPathComponent("vocab.json"))

    #expect(ParakeetManager.missingFiles(["vocab.json", "Encoder.mlmodelc"], in: dir) == ["Encoder.mlmodelc"])
    #expect(ParakeetManager.missingFiles(["vocab.json"], in: dir).isEmpty)
    #expect(!ParakeetManager.missingFiles([], in: dir).isEmpty)
  }
}
