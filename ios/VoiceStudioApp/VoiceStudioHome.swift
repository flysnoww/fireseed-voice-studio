import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoiceStudioCore

struct VoiceStudioHome: View {
    @StateObject private var model: VoiceStudioModel
    @State private var voiceName = "My voice"
    @State private var text = ""
    @Environment(\.openURL) private var openURL

    init(model: VoiceStudioModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Voice source") {
                    HStack {
                        Button(model.isRecording ? "Stop recording" : (model.isRequestingPermission ? "Requesting microphone…" : "Record")) {
                            if model.isRecording {
                                model.stopRecording()
                            } else {
                                Task { await model.startRecording() }
                            }
                        }
                        .tint(model.isRecording ? .red : .accentColor)
                        .disabled(model.isRequestingPermission && !model.isRecording)
                        .accessibilityIdentifier("recordButton")

                        ImportAudioButton(model: model)
                    }
                    HStack {
                        unavailableSource("Random")
                        unavailableSource("Built-in")
                    }
                    Text(LocalizedStringKey(model.statusMessage))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("voiceStatus")

                    if model.isRecording {
                        Label("Recording in progress", systemImage: "record.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("recordingState")
                    }
                    if model.microphonePermissionDenied {
                        Button("Open Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(url)
                        }
                        .accessibilityIdentifier("microphoneSettingsButton")
                    }
                }

                if let reference = model.currentReference {
                    Section("Current Reference") {
                        HStack(spacing: 4) {
                            Text("Ready ·")
                            Text(sourceLocalizationKey(for: reference.source))
                        }
                            .accessibilityIdentifier("currentReferenceState")
                        HStack {
                            Button("Play") { model.playCurrentAudio() }
                                .accessibilityIdentifier("playReferenceButton")
                            Button("Stop") { model.stopPlayback() }
                                .disabled(!model.isPlaying)
                                .accessibilityIdentifier("stopPlaybackButton")
                        }
                        TextField("Voice name", text: $voiceName)
                            .accessibilityIdentifier("voiceNameField")
                        Button("Save Voice") { model.saveVoice(name: voiceName) }
                            .disabled(!model.canSaveVoice)
                            .accessibilityIdentifier("saveVoiceButton")
                    }
                }

                Section("Text") {
                    TextField("Enter text for your voice", text: $text, axis: .vertical)
                        .lineLimit(2...5)
                    HStack {
                        Button("Preview") {}.disabled(true)
                        Button("Generate") {}.disabled(true)
                    }
                    Text("Preview and Generate will be available when a renderer is added.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !model.savedVoices.isEmpty {
                    Section("Saved voices") {
                        ForEach(model.savedVoices) { voice in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(voice.name)
                                    Text(sourceLocalizationKey(for: voice.sourceType))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Play") { model.playVoiceReference(voice) }
                                    .labelStyle(.iconOnly)
                                    .accessibilityLabel("Play \(voice.name) reference")
                                Button("Stop") { model.stopPlayback() }
                                    .labelStyle(.iconOnly)
                                    .accessibilityLabel("Stop playback")
                            }
                        }
                    }
                }
            }
            // Form rows can contain multiple actions; each button owns its tap.
            .buttonStyle(.borderless)
            .navigationTitle("Voice Studio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "person.circle")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settingsButton")
                }
            }
        }
    }

    private func unavailableSource(_ title: String) -> some View {
        Button {
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("Coming later").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .disabled(true)
    }

    private func sourceLocalizationKey(for source: VoiceSourceType) -> LocalizedStringKey {
        switch source {
        case .record: "Recorded"
        case .imported: "Imported"
        case .random: "Random"
        case .builtIn: "Built-in"
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var languagePreference: AppLanguagePreference

    var body: some View {
        Form {
            Section("Account") {
                NavigationLink(destination: AccountPlaceholderView()) {
                    Label("Account", systemImage: "person.circle")
                    Text("Not signed in").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("accountPlaceholderLink")
            }

            Section("Language") {
                Picker("App Language", selection: Binding(
                    get: { languagePreference.language },
                    set: { languagePreference.set($0) }
                )) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .accessibilityIdentifier("appLanguagePicker")
            }
        }
        .navigationTitle("Settings")
    }
}

private struct AccountPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Label("Not signed in", systemImage: "person.circle")
                .font(.headline)
            Text("Sign in will be available after the shared Fireseed account system is integrated.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Account")
    }
}

private struct ImportAudioButton: View {
    @ObservedObject var model: VoiceStudioModel
    @State private var isImporterPresented = false

    var body: some View {
        Button("Import") { isImporterPresented = true }
            .disabled(model.isRecording || model.isRequestingPermission)
            .accessibilityIdentifier("importButton")
            .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    model.importAudio(from: url)
                case .failure(let error):
                    model.report(error)
                }
            }
    }
}
