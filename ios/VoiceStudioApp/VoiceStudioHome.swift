import SwiftUI
import UniformTypeIdentifiers
import VoiceStudioCore

struct VoiceStudioHome: View {
    @StateObject private var model: VoiceStudioModel
    @State private var voiceName = "My voice"
    @State private var text = ""
    @State private var showingImporter = false

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

                        Button("Import") { showingImporter = true }
                            .disabled(model.isRecording || model.isRequestingPermission)
                    }
                    HStack {
                        unavailableSource("Random")
                        unavailableSource("Built-in")
                    }
                    if model.currentAudio != nil {
                        HStack {
                            Button("Play reference") { model.playCurrentAudio() }
                            Button("Stop") { model.stopPlayback() }
                                .disabled(!model.isPlaying)
                        }
                        TextField("Voice name", text: $voiceName)
                        Button("Save Voice") { model.saveVoice(name: voiceName) }
                            .disabled(model.isRecording || model.isRequestingPermission)
                    }
                    Text(model.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("voiceStatus")
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
            .navigationTitle("Voice Studio")
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
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
