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
                    Text(model.statusMessage)
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
                        Text("Ready · \(reference.sourceLabel)")
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
                                    Text(voice.sourceType.rawValue.capitalized)
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
