import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoiceStudioCore

struct VoiceStudioHome: View {
    @StateObject private var model: VoiceStudioModel
    @State private var voiceName = "My voice"
    @State private var defaultVoiceName = "My voice"
    @State private var voiceNameWasEdited = false
    @State private var generationText = ""
    @State private var generationVoiceID: UUID?
    @State private var generationLanguage = "zh"
    @State private var isRendererPackImporterPresented = false
    @State private var voiceToDelete: VoiceAsset?
    @Environment(\.locale) private var locale
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
                        TextField("Voice Name", text: Binding(
                            get: { voiceName },
                            set: { voiceName = $0 }
                        ), onEditingChanged: { isEditing in
                            if isEditing { voiceNameWasEdited = true }
                        })
                            .accessibilityIdentifier("voiceNameField")
                        Button("Save Voice") { model.saveVoice(name: voiceName) }
                            .disabled(!model.canSaveVoice || voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("saveVoiceButton")
                    }
                }

                Section("Create speech") {
                    Button(model.isInstallingRenderer ? "Loading local voice engine…" :
                           (model.isRendererReady ? "Local voice engine ready" : "Import local voice pack")) {
                        isRendererPackImporterPresented = true
                    }
                    .disabled(model.isInstallingRenderer || model.isGeneratingSpeech)
                    .accessibilityIdentifier("rendererPackButton")

                    if model.savedVoices.isEmpty {
                        Text("Save a recorded or imported voice to start creating speech.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Voice", selection: Binding(
                            get: { generationVoiceID ?? model.savedVoices[0].id },
                            set: { generationVoiceID = $0 }
                        )) {
                            ForEach(model.savedVoices) { voice in
                                Text(voice.name).tag(voice.id)
                            }
                        }
                        .accessibilityIdentifier("generationVoicePicker")

                        Picker("Speech language", selection: $generationLanguage) {
                            Text("Chinese").tag("zh")
                            Text("English").tag("en")
                        }
                        .accessibilityIdentifier("speechLanguagePicker")

                        TextField("Enter text for your voice", text: $generationText, axis: .vertical)
                            .lineLimit(2...5)
                        Button(model.isGeneratingSpeech ? "Generating…" : "Generate") {
                            guard let voiceID = generationVoiceID ?? model.savedVoices.first?.id else { return }
                            Task { await model.generateSpeech(text: generationText, voiceID: voiceID,
                                                             language: generationLanguage) }
                        }
                        .disabled(!model.isRendererReady || model.isGeneratingSpeech ||
                                  generationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("generateSpeechButton")
                    }

                    if model.generatedAudio != nil {
                        HStack {
                            Button("Play generated speech") { model.playGeneratedAudio() }
                                .disabled(model.isGeneratingSpeech)
                            if model.generatedAudio?.persistenceState == .temporary {
                                Button("Save Audio") { model.saveGeneratedAudio() }
                                    .disabled(model.isGeneratingSpeech)
                            } else {
                                Label("Audio saved", systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !model.savedVoices.isEmpty {
                    savedVoiceLibrarySection
                }
            }
            // Form rows can contain multiple actions; each button owns its tap.
            .buttonStyle(.borderless)
            .navigationTitle("Voice Studio")
            .onAppear(perform: updateDefaultVoiceName)
            .task { await model.restoreLocalRenderer() }
            .onChange(of: model.currentReference?.asset.id) { _, newID in
                guard newID != nil else { return }
                voiceNameWasEdited = false
                updateDefaultVoiceName()
            }
            .onChange(of: locale.identifier) { _, _ in updateDefaultVoiceName() }
            .onChange(of: model.savedVoices.map(\.id)) { _, voiceIDs in
                if generationVoiceID.map({ !voiceIDs.contains($0) }) ?? true {
                    generationVoiceID = voiceIDs.first
                }
            }
            .fileImporter(isPresented: $isRendererPackImporterPresented,
                          allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let folder = urls.first else { return }
                    Task { await model.installRendererPack(from: folder) }
                case .failure(let error):
                    model.report(error)
                }
            }
            .confirmationDialog("Delete Voice?", isPresented: Binding(
                get: { voiceToDelete != nil },
                set: { if !$0 { voiceToDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let voiceToDelete { model.deleteSavedVoice(id: voiceToDelete.id) }
                    voiceToDelete = nil
                }
                Button("Cancel", role: .cancel) { voiceToDelete = nil }
            } message: {
                Text("This voice and its saved reference audio will be removed.")
            }
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

    private var savedVoiceLibrarySection: some View {
        Section("Saved Voices") {
            Menu {
                ForEach(SavedVoiceFilter.allCases) { filter in
                    Button {
                        model.setSavedVoiceFilter(filter)
                    } label: {
                        if model.savedVoiceFilter == filter {
                            Label(filterLocalizationKey(for: filter), systemImage: "checkmark")
                        } else {
                            Text(filterLocalizationKey(for: filter))
                        }
                    }
                }
            } label: {
                Label(filterLocalizationKey(for: model.savedVoiceFilter), systemImage: "line.3.horizontal.decrease")
            }
            .accessibilityIdentifier("savedVoiceFilterMenu")

            if model.pagedSavedVoices.isEmpty {
                Text("No voices in this filter.")
                    .foregroundStyle(.secondary)
            }

            ForEach(model.pagedSavedVoices) { voice in
                savedVoiceRow(voice)
            }

            if model.savedVoicePageCount > 1 {
                HStack {
                    Button("Previous") { model.setSavedVoicePage(model.savedVoicePage - 1) }
                        .disabled(model.savedVoicePage == 0)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Page")
                        Text("\(model.savedVoicePage + 1) / \(model.savedVoicePageCount)")
                    }
                    .accessibilityIdentifier("savedVoicePageState")
                    Spacer()
                    Button("Next") { model.setSavedVoicePage(model.savedVoicePage + 1) }
                        .disabled(model.savedVoicePage >= model.savedVoicePageCount - 1)
                }
            }
        }
    }

    private func savedVoiceRow(_ voice: VoiceAsset) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(voice.name)
                HStack(spacing: 4) {
                    Text(sourceLocalizationKey(for: voice.sourceType))
                    Text("·")
                    Text(SavedVoiceLibrary.formattedDuration(voice.referenceAudio.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("Saved")
                    Text(voice.savedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                }
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
            Button {
                voiceToDelete = voice
            } label: {
                Image(systemName: "trash")
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Delete")
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

    private func filterLocalizationKey(for filter: SavedVoiceFilter) -> LocalizedStringKey {
        switch filter {
        case .time: "Time"
        case .imported: "Imported"
        case .recorded: "Recorded"
        }
    }

    private func updateDefaultVoiceName() {
        guard !voiceNameWasEdited, let reference = model.currentReference else { return }
        let key: String
        switch reference.source {
        case .record: key = "Recorded Voice"
        case .imported: key = "Imported Voice"
        case .random, .builtIn: key = "My voice"
        }
        let value = String(localized: String.LocalizationValue(key), locale: locale)
        defaultVoiceName = value
        voiceName = value
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
