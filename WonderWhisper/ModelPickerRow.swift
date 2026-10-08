import SwiftUI

/// Popup picker over the user's favorite LLMs, showing friendly names. A current selection
/// that is not a favorite (for example a raw model ID from an older version) stays selectable
/// under "Current" so the picker never silently changes it.
struct ModelPickerRow: View {
  let title: String
  @Binding var selection: String
  let favoriteModels: [FavoriteOpenRouterModel]

  var body: some View {
    Picker(selection: $selection) {
      if !selectionIsFavorite {
        Section("Current") {
          Text(selection).tag(selection)
        }
      }
      if !favoriteModels.isEmpty {
        Section("Favorite models") {
          ForEach(favoriteModels) { model in
            Text(model.name).tag(model.id)
          }
        }
      }
    } label: {
      Text(title)
      if favoriteModels.isEmpty {
        Text("Add favorite models in Settings → Models.")
      }
    }
    .pickerStyle(.menu)
  }

  private var selectionIsFavorite: Bool {
    favoriteModels.contains {
      $0.id.caseInsensitiveCompare(selection) == .orderedSame
    }
  }
}
