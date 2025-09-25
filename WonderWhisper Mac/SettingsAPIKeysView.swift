import SwiftUI

struct SettingsAPIKeysView: View {
    @ObservedObject var vm: DictationViewModel
    @State private var groqKeyInput: String = ""
    @State private var assemblyAIKeyInput: String = ""
    @State private var deepgramKeyInput: String = ""
    @State private var openrouterKeyInput: String = ""
    @State private var cerebrasKeyInput: String = ""

    private let keychain = KeychainService()
    private var hasGroq: Bool { keychain.getSecret(forKey: AppConfig.groqAPIKeyAlias) != nil }
    private var hasAssemblyAI: Bool { keychain.getSecret(forKey: AppConfig.assemblyAIAPIKeyAlias) != nil }
    private var hasDeepgram: Bool { keychain.getSecret(forKey: AppConfig.deepgramAPIKeyAlias) != nil }
    private var hasOpenRouter: Bool { keychain.getSecret(forKey: AppConfig.openrouterAPIKeyAlias) != nil }
    private var hasCerebras: Bool { keychain.getSecret(forKey: AppConfig.cerebrasAPIKeyAlias) != nil }

    var body: some View {
        Form {
            Section(header: HStack(spacing: 6) { Text("Groq"); if hasGroq { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).help("Key stored") } }) {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Groq API Key", text: $groqKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                    HStack(spacing: 8) {
                        Button("Save Groq Key") { vm.saveGroqApiKey(groqKeyInput); groqKeyInput = "" }
                        Text("Stored as \(AppConfig.groqAPIKeyAlias)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: HStack(spacing: 6) { Text("AssemblyAI"); if hasAssemblyAI { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).help("Key stored") } }) {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("AssemblyAI API Key", text: $assemblyAIKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                    HStack(spacing: 8) {
                        Button("Save AssemblyAI Key") { vm.saveAssemblyAIKey(assemblyAIKeyInput); assemblyAIKeyInput = "" }
                        Text("Stored as \(AppConfig.assemblyAIAPIKeyAlias)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: HStack(spacing: 6) { Text("Deepgram"); if hasDeepgram { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).help("Key stored") } }) {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Deepgram API Key", text: $deepgramKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                    HStack(spacing: 8) {
                        Button("Save Deepgram Key") { vm.saveDeepgramKey(deepgramKeyInput); deepgramKeyInput = "" }
                        Text("Stored as \(AppConfig.deepgramAPIKeyAlias)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section(header: HStack(spacing: 6) { Text("OpenRouter"); if hasOpenRouter { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).help("Key stored") } }) {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("OpenRouter API Key", text: $openrouterKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                    HStack(spacing: 8) {
                        Button("Save OpenRouter Key") { vm.saveOpenRouterKey(openrouterKeyInput); openrouterKeyInput = "" }
                        Text("Stored as \(AppConfig.openrouterAPIKeyAlias)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            Section(header: HStack(spacing: 6) { Text("Cerebras"); if hasCerebras { Image(systemName: "checkmark.circle.fill").foregroundColor(.green).help("Key stored") } }) {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Cerebras API Key", text: $cerebrasKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                    HStack(spacing: 8) {
                        Button("Save Cerebras Key") { vm.saveCerebrasKey(cerebrasKeyInput); cerebrasKeyInput = "" }
                        Text("Stored as \(AppConfig.cerebrasAPIKeyAlias)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            }
        }
        .formStyle(.grouped)
        .padding()
    }
}


