import SwiftUI

struct SettingsAPIKeysView: View {
  @ObservedObject var vm: DictationViewModel
  @State private var groqKeyInput = ""
  @State private var assemblyAIKeyInput = ""
  @State private var deepgramKeyInput = ""
  @State private var sonioxKeyInput = ""
  @State private var openrouterKeyInput = ""
  @State private var cerebrasKeyInput = ""

  private let keychain = KeychainService()
  private var hasGroq: Bool { keychain.getSecret(forKey: AppConfig.groqAPIKeyAlias) != nil }
  private var hasAssemblyAI: Bool { keychain.getSecret(forKey: AppConfig.assemblyAIAPIKeyAlias) != nil }
  private var hasDeepgram: Bool { keychain.getSecret(forKey: AppConfig.deepgramAPIKeyAlias) != nil }
  private var hasSoniox: Bool { keychain.getSecret(forKey: AppConfig.sonioxAPIKeyAlias) != nil }
  private var hasOpenRouter: Bool { keychain.getSecret(forKey: AppConfig.openrouterAPIKeyAlias) != nil }
  private var hasCerebras: Bool { keychain.getSecret(forKey: AppConfig.cerebrasAPIKeyAlias) != nil }

  var body: some View {
    Form {
      Section(header: keyHeader("Groq", hasKey: hasGroq)) {
        apiKeyField(
          title: "Groq API Key",
          binding: $groqKeyInput,
          saveTitle: "Save Groq Key",
          hint: AppConfig.groqAPIKeyAlias,
          action: { vm.saveGroqApiKey(groqKeyInput); groqKeyInput = "" }
        )
      }

      Section(header: keyHeader("AssemblyAI", hasKey: hasAssemblyAI)) {
        apiKeyField(
          title: "AssemblyAI API Key",
          binding: $assemblyAIKeyInput,
          saveTitle: "Save AssemblyAI Key",
          hint: AppConfig.assemblyAIAPIKeyAlias,
          action: { vm.saveAssemblyAIKey(assemblyAIKeyInput); assemblyAIKeyInput = "" }
        )
      }

      Section(header: keyHeader("Deepgram", hasKey: hasDeepgram)) {
        apiKeyField(
          title: "Deepgram API Key",
          binding: $deepgramKeyInput,
          saveTitle: "Save Deepgram Key",
          hint: AppConfig.deepgramAPIKeyAlias,
          action: { vm.saveDeepgramKey(deepgramKeyInput); deepgramKeyInput = "" }
        )
      }

      Section(header: keyHeader("Soniox", hasKey: hasSoniox)) {
        apiKeyField(
          title: "Soniox API Key",
          binding: $sonioxKeyInput,
          saveTitle: "Save Soniox Key",
          hint: AppConfig.sonioxAPIKeyAlias,
          action: { vm.saveSonioxKey(sonioxKeyInput); sonioxKeyInput = "" }
        )
      }

      Section(header: keyHeader("OpenRouter", hasKey: hasOpenRouter)) {
        apiKeyField(
          title: "OpenRouter API Key",
          binding: $openrouterKeyInput,
          saveTitle: "Save OpenRouter Key",
          hint: AppConfig.openrouterAPIKeyAlias,
          action: { vm.saveOpenRouterKey(openrouterKeyInput); openrouterKeyInput = "" }
        )
      }

      Section(header: keyHeader("Cerebras", hasKey: hasCerebras)) {
        apiKeyField(
          title: "Cerebras API Key",
          binding: $cerebrasKeyInput,
          saveTitle: "Save Cerebras Key",
          hint: AppConfig.cerebrasAPIKeyAlias,
          action: { vm.saveCerebrasKey(cerebrasKeyInput); cerebrasKeyInput = "" }
        )
      }
    }
    .formStyle(.grouped)
    .padding()
  }

  private func keyHeader(_ title: String, hasKey: Bool) -> some View {
    HStack(spacing: 6) {
      Text(title)
      if hasKey {
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
          .help("Key stored")
      }
    }
  }

  private func apiKeyField(
    title: String,
    binding: Binding<String>,
    saveTitle: String,
    hint: String,
    action: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      SecureField(title, text: binding)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 420)
      HStack(spacing: 8) {
        Button(saveTitle, action: action)
        Text("Stored as \(hint)")
          .font(.caption)
          .foregroundColor(.secondary)
      }
    }
  }
}
