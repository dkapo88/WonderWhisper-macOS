import AppKit
import SwiftUI

/// Status, Download / Retry and Show in Finder for the selected on-device model, beside the
/// transcription picker. Everything shown comes from `TranscriptionModelStatusCenter`, which
/// outlives the Settings window.
struct LocalModelStatusRow: View {
  let model: LocalTranscriptionModel
  @ObservedObject var status: TranscriptionModelStatusCenter

  var body: some View {
    let current = status.status(for: model)
    LabeledContent {
      HStack(spacing: DesignTokens.Spacing.xSmall) {
        if current.offersDownload {
          Button(current.isRetry ? "Retry" : "Download") {
            status.download(model)
          }
        }
        Button("Show in Finder") {
          NSWorkspace.shared.selectFile(finderPath, inFileViewerRootedAtPath: "")
        }
      }
    } label: {
      Text("Status")
      Text(sizeDetail)
    }

    badge(for: current)

    if case .parakeet(let kind) = model, let fallback = status.fallback(for: kind) {
      StatusBadge(.warning, "Dictation uses \(fallback.shortName) until \(kind.shortName) is downloaded.")
    }
  }

  @ViewBuilder private func badge(for current: LocalModelStatus) -> some View {
    switch current {
    case .frameworkMissing:
      StatusBadge(.error, "Framework missing")
    case .unsupported(let reason):
      StatusBadge(.error, reason)
    case .notDownloaded:
      StatusBadge(.neutral, notDownloadedText)
    case .downloading(let progress):
      if let progress {
        ProgressView(value: progress, total: 1) {
          Text("Downloading \(model.displayName)… \(Int((progress * 100).rounded()))%")
            .settingsFootnote()
        }
      } else {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
          ProgressView().controlSize(.small)
          Text("Downloading \(model.displayName)…").settingsFootnote()
        }
      }
    case .downloadFailed(let message):
      StatusBadge(.error, "Download failed: \(message)")
    case .downloaded:
      StatusBadge(.neutral, downloadedText)
    case .loading:
      HStack(spacing: DesignTokens.Spacing.xSmall) {
        ProgressView().controlSize(.small)
        Text("Loading \(model.displayName)…").settingsFootnote()
      }
    case .ready:
      StatusBadge(.ok, model == .qwen ? "Loaded and ready" : "Ready")
    case .loadFailed(let message):
      StatusBadge(.error, "Couldn't load \(model.displayName): \(message)")
    }
  }

  private var notDownloadedText: String {
    switch model {
    case .parakeet(let kind):
      // With a downloaded stand-in, the fallback line below says what dictation runs instead.
      if status.fallback(for: kind) != nil { return "Not downloaded." }
      return "Not downloaded. Downloads on your first dictation, or download now."
    case .qwen: return "Not downloaded."
    }
  }

  private var downloadedText: String {
    switch model {
    case .parakeet: return "Downloaded, not loaded yet."
    case .qwen: return "Downloaded. Loads when you dictate."
    }
  }

  private var sizeDetail: String {
    switch model {
    case .parakeet(let kind): return "\(kind.approximateDownloadSize), then fully offline."
    case .qwen: return "About 1 GB from Hugging Face, then fully offline."
    }
  }

  private var finderPath: String {
    switch model {
    case .parakeet(let kind): return ParakeetManager.effectiveModelsDirectory(for: kind).path
    case .qwen: return QwenASRManager.effectiveCacheDirectory().path
    }
  }
}
