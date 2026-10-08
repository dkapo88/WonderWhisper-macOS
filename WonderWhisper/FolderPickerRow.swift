import AppKit
import SwiftUI

/// Settings row for a folder: the folder name with its full path underneath, plus
/// Choose / Show in Finder / Clear actions.
struct FolderPickerRow: View {
  let title: String
  let path: String?
  let placeholder: String
  var canChoose = true
  var showsClear = false
  var clearTitle = "Clear"
  let onChoose: () -> Void
  var onClear: () -> Void = {}

  var body: some View {
    LabeledContent {
      HStack(spacing: DesignTokens.Spacing.xSmall) {
        Button("Choose…", action: onChoose)
          .disabled(!canChoose)
          .accessibilityLabel("Choose \(title)")

        if path != nil || showsClear {
          Menu {
            if let path {
              Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
              }
            }
            if showsClear {
              Button(clearTitle, role: .destructive, action: onClear)
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .help("More actions for \(title)")
          .accessibilityLabel("More actions for \(title)")
        }
      }
    } label: {
      Text(title)
      Text(displayPath)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(path ?? placeholder)
    }
  }

  private var displayPath: String {
    guard let path else { return placeholder }
    return (path as NSString).abbreviatingWithTildeInPath
  }
}
