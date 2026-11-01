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

  @Test func unsetReadsAsTheNewInstallDefaultBarkClean() {
    #expect(ParakeetModelKind(storedValue: nil) == .barkClean)
    #expect(ParakeetModelKind.newInstallDefault == .barkClean)
    #expect(ParakeetModelKind.legacyDefault == .unified)
  }

  @Test func barkCleanSelectionRoundTrips() {
    #expect(ParakeetModelKind.barkClean.rawValue == "bark-clean")
    #expect(ParakeetModelKind(storedValue: "bark-clean") == .barkClean)
    #expect(ParakeetModelKind(storedValue: "Bark-Clean") == .barkClean)
  }

  @Test func everythingElseReadsAsUnified() {
    #expect(ParakeetModelKind(storedValue: "") == .unified)
    #expect(ParakeetModelKind(storedValue: "unified") == .unified)
    #expect(ParakeetModelKind(storedValue: "v2") == .unified)
    #expect(ParakeetModelKind(storedValue: "something-new") == .unified)
  }

  @Test func selectionKeepsTheExistingDefaultsKeyAndWritesUltra() {
    #expect(ParakeetModelKind.defaultsKey == "parakeet.version")
    #expect(ParakeetModelKind.ultra.rawValue == "ultra")
    #expect(ParakeetModelKind.unified.rawValue == "unified")
    #expect(ParakeetModelKind.allCases == [.barkClean, .unified, .ultra])
  }

  @Test func pickerLabelsNameLanguageAndModel() {
    #expect(ParakeetModelKind.unified.displayName == "English (Unified)")
    #expect(ParakeetModelKind.ultra.displayName == "Multilingual (Ultra)")
    #expect(ParakeetModelKind.barkClean.displayName == "Clean English (Bark Clean)")
  }

  @Test func modelIdentifiersNameTheirModel() {
    #expect(ParakeetModelKind(modelIdentifier: "parakeet-bark-clean") == .barkClean)
    #expect(ParakeetModelKind(modelIdentifier: "parakeet-unified") == .unified)
    #expect(ParakeetModelKind(modelIdentifier: "parakeet-ultra") == .ultra)
    #expect(ParakeetModelKind(modelIdentifier: "parakeet-v3") == .ultra)
    #expect(ParakeetModelKind(modelIdentifier: "Parakeet-V2") == .ultra)
    #expect(ParakeetModelKind(modelIdentifier: "parakeet-local") == nil)
  }

  @Test func capabilitiesKeepMeetingsAndStreamingOnUnified() {
    #expect(ParakeetModelKind.barkClean.tdtVersion == .bark3Clean)
    #expect(ParakeetModelKind.ultra.tdtVersion == .ultra)
    #expect(ParakeetModelKind.unified.tdtVersion == nil)
    #expect(ParakeetModelKind.allCases.filter(\.supportsLiveStreaming) == [.unified])
    #expect(ParakeetModelKind.barkCleanFallbackOrder == [.unified, .ultra])
  }

  @Test func onlyBarkCleanCarriesACCBYCreditChain() throws {
    let credit = try #require(ParakeetModelKind.barkClean.credit)
    #expect(credit.licenseURL.absoluteString == "https://creativecommons.org/licenses/by/4.0/")
    #expect(credit.links.map(\.url.absoluteString) == [
      "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
      "https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Clean",
      "https://huggingface.co/FluidInference/bark-3.0-coreml"
    ])
    #expect(credit.summary.contains("NVIDIA Parakeet TDT 0.6B v3"))
    #expect(credit.summary.contains("Conway Research"))
    #expect(credit.summary.contains("FluidInference"))
    #expect(ParakeetModelKind.unified.credit == nil)
    #expect(ParakeetModelKind.ultra.credit == nil)
  }

  // MARK: - Folder names (re-verify on every FluidAudio bump)

  @Test func folderNamesMatchFluidAudioRepoFolders() {
    #expect(ParakeetModelKind.unified.folderName == "parakeet-unified-en-0.6b")
    #expect(ParakeetModelKind.ultra.folderName == "parakeet-ultra")
    #expect(ParakeetModelKind.barkClean.folderName == "bark-3.0-clean")
    #expect(ParakeetModelKind.unified.folderName == Repo.parakeetUnified.folderName)
    #expect(ParakeetModelKind.ultra.folderName == Repo.parakeetUltra.folderName)
    #expect(ParakeetModelKind.barkClean.folderName == Repo.bark3Clean.folderName)
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

    // Bark Clean ships the v3 layout, like Ultra.
    #expect(ParakeetModelKind.barkClean.requiredFiles == ultra)
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
