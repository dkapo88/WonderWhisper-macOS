import SwiftUI

struct SimpleScratchpadView: View {
  @ObservedObject var vm: DictationViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Scratchpad")
          .font(.title2.weight(.semibold))
        Text("Type freely or use the Simple Dictation shortcut to drop text here. The scratchpad remembers its content between launches.")
          .font(.callout)
          .foregroundColor(.secondary)
      }

      ZStack(alignment: .topLeading) {
        TextEditor(text: $vm.simpleScratchpadText)
          .font(.body)
          .lineSpacing(4)
          .padding(.top, 12)
          .padding(.leading, 4)
          .frame(minHeight: 260)
        if vm.simpleScratchpadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text("Start jotting notes or dictate using your hotkey…")
            .font(.callout)
            .foregroundColor(.secondary)
            .padding(.top, 16)
            .padding(.leading, 10)
        }
      }
      .overlay(
        RoundedRectangle(cornerRadius: 14)
          .stroke(Color.secondary.opacity(0.2))
      )
      .background(
        RoundedRectangle(cornerRadius: 14)
          .fill(Color(nsColor: .textBackgroundColor))
      )

      Spacer()
    }
    .padding(24)
  }
}

#Preview {
  SimpleScratchpadView(vm: DictationViewModel())
}
