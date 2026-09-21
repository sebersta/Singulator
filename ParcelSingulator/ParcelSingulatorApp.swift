import FoundationModels
import SwiftUI

@main
struct ParcelSingulatorApp: App {
    var body: some Scene {
        WindowGroup("") {
            SettingsView()
                .frame(width: 480)
        }
        .windowResizability(.contentSize)
    }
}

private struct SettingsView: View {
    @State private var parcelKey = ParcelKeychain.load() ?? ""
    @State private var hasSavedKey = !(ParcelKeychain.load()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    @State private var parcelAutomationEnabled = ParcelKeychain.isAutomationEnabled
    @State private var result = ""
    @State private var isValidating = false
    @State private var triggerWords = ParcelKeychain.triggerWords
    @State private var triggerWordsResult = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Parcel Singulator", systemImage: "shippingbox.fill")
                .font(.largeTitle.bold())
            Text("Singulator uses Apple Intelligence to extract tracking numbers from your emails locally.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            Label(modelStatus, systemImage: modelReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(modelReady ? .green : .orange)

            if deviceEligible {
                Text("Open Mail → Settings → Extensions and enable Parcel Singulator.")
                    .font(.callout)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Trigger words").font(.headline)
                    TextField("track, kollinr", text: $triggerWords, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .accessibilityLabel("Trigger words")
                        .onChange(of: triggerWords) {
                            do {
                                try ParcelKeychain.saveTriggerWords(triggerWords)
                                triggerWordsResult = ""
                            } catch {
                                triggerWordsResult = error.localizedDescription
                            }
                        }
                    Text("Separate words or phrases with commas. Any match in the email body triggers detection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !triggerWordsResult.isEmpty {
                        Text(triggerWordsResult)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle("Automatically add shipments to Parcel", isOn: Binding(
                    get: { parcelAutomationEnabled },
                    set: { isEnabled in
                        do {
                            try ParcelKeychain.setAutomationEnabled(isEnabled)
                            parcelAutomationEnabled = isEnabled
                            result = ""
                        } catch {
                            result = error.localizedDescription
                        }
                    }
                ))

                if parcelAutomationEnabled {
                    SecureField("Parcel API key", text: $parcelKey)
                        .textFieldStyle(.roundedBorder)

                    Link("Get Parcel API", destination: URL(string: "https://web.parcelapp.net")!)

                    HStack(alignment: .center) {
                        Button {
                            Task { await save() }
                        } label: {
                            if isValidating {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Save API Key")
                            }
                        }
                            .buttonStyle(.borderedProminent)
                            .fixedSize()
                            .disabled(isValidating || parcelKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text(result)
                            .foregroundStyle(result == "Saved" ? .green : .red)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                }
            }

        }
        .padding(28)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var modelReady: Bool { SystemLanguageModel.default.isAvailable }

    private var deviceEligible: Bool {
        if case .unavailable(.deviceNotEligible) = SystemLanguageModel.default.availability {
            false
        } else {
            true
        }
    }

    private var modelStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: "Apple Foundation Model available"
        case .unavailable(.deviceNotEligible): "This Mac does not support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): "Enable Apple Intelligence in System Settings"
        case .unavailable(.modelNotReady): "Apple Intelligence is still preparing its model"
        @unknown default: "Apple Foundation Model is unavailable"
        }
    }

    @MainActor
    private func save() async {
        let key = parcelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        isValidating = true
        defer { isValidating = false }
        do {
            try await ShipmentProcessor.validateAPIKey(key)
            try ParcelKeychain.save(key)
            hasSavedKey = true
            result = "Saved"
        } catch {
            result = error.localizedDescription
        }
    }
}
