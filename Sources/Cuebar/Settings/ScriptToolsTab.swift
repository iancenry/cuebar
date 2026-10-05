import SwiftUI
import PromptCore

/// "Script Tools": provider, endpoint, model, key, and the trim budget.
///
/// The key row is a `SecureField` that writes straight to the keychain and
/// never reads the secret back into the settings file. The rest of the page
/// is ordinary preferences. What is *not* here is a "test connection" button:
/// a round trip costs a token and tells the user almost nothing a real
/// rewrite would not tell them better.
struct ScriptToolsTab: View {
    @Bindable var settings: SettingsStore
    @State private var draftKey = ""
    @State private var hasKey = false
    /// The outcome of the last write attempt, not a flag flipped on tap: a
    /// keychain that refuses the write is a fact the user has to be told.
    @State private var keyError: String?

    private var ai: AISettings { settings.settings.ai }

    var body: some View {
        SettingsPage(title: "Script Tools",
                     subtitle: "Tidy, pace and rewrite a script with a model of your choosing.") {
            SettingsSection(title: "Provider") {
                SettingRow(label: "Service") {
                    Picker("", selection: Binding(
                        get: { ai.provider },
                        set: { new in
                            var next = ai
                            next.setProvider(new)
                            settings.settings.ai = next
                        })) {
                        ForEach(AIRequest.Provider.allCases, id: \.self) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                SettingRow(label: "Endpoint") {
                    TextField("https://api.anthropic.com",
                              text: Binding(get: { ai.baseURL },
                                            set: { settings.settings.ai.baseURL = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                }
                SettingRow(label: "Model") {
                    TextField("model name",
                              text: Binding(get: { ai.model },
                                            set: { settings.settings.ai.model = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                }
                Text(ai.provider.needsKey
                     ? "Requests go to \(ai.provider.label) with your key."
                     : "A local server needs no key — the field below is ignored.")
                    .font(.caption)
                    .foregroundStyle(CuePalette.muted)
            }

            SettingsSection(title: "Key") {
                SettingRow(label: ai.provider.needsKey ? "API key" : "API key") {
                    HStack(spacing: 8) {
                        SecureField(hasKey ? "Paste your key to replace it"
                                           : "Paste your key",
                                    text: $draftKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                        Button("Save") {
                            // The write decides whether it worked. Reporting
                            // success on an `errSecInteractionNotAllowed` left
                            // the user believing a key was stored when nothing
                            // was, and every request then failed as "no key".
                            if Keychain.write(draftKey, "scripttools") {
                                hasKey = true
                                keyError = nil
                                draftKey = ""
                            } else {
                                keyError = "The keychain refused that key."
                            }
                        }
                        .disabled(draftKey.isEmpty)
                        if hasKey {
                            Button("Remove") {
                                Keychain.delete("scripttools")
                                hasKey = false
                                draftKey = ""
                                keyError = nil
                            }
                        }
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: hasKey ? "key" : "key.slash")
                        .font(.system(size: 11))
                    Text(hasKey ? "A key is saved in the login keychain."
                                : "No key saved.")
                    if let keyError {
                        Text(keyError).foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(CuePalette.muted)
                Text("The key is kept in the login keychain, not in Cuebar's preferences "
                     + "file — a settings file gets copied to the next Mac, a keychain "
                     + "item does not.")
                    .font(.caption)
                    .foregroundStyle(CuePalette.inkMuted)
            }

            SettingsSection(title: "Budget") {
                SettingRow(label: "Trim to") {
                    HStack(spacing: 8) {
                        Stepper(value: Binding(get: { ai.minutes },
                                               set: { settings.settings.ai.minutes = $0 }),
                                in: 1...120) {
                            Text("\(ai.minutes) min")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(CuePalette.ink)
                        }
                        Text("≈ \(ai.minutes * 140) words")
                            .font(.caption)
                            .foregroundStyle(CuePalette.muted)
                    }
                }
                Text("Used by “Trim to a length”. Paces are computed at 140 words a "
                     + "minute, which is roughly how fast people speak on stage.")
                    .font(.caption)
                    .foregroundStyle(CuePalette.inkMuted)
            }
        }
        .onAppear {
            // A `Bool`, never the key. Holding the secret in a `@State`
            // property keeps it resident in memory for as long as the settings
            // window is open, and every read of it is a chance for it to end
            // up somewhere it should not be.
            hasKey = Keychain.hasKey("scripttools")
        }
    }
}