import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoiceStudioCore

struct VoiceStudioHome: View {
    @StateObject private var model: VoiceStudioModel
    @State private var voiceName = "My voice"
    @State private var voiceNameWasEdited = false
    @State private var generationText = ""
    @State private var generationVoice = VoiceSelection.systemDefault
    @State private var generationLanguage = "en"
    @State private var generationAccent: String?
    @State private var speed = 1.0
    @State private var pitch = 0.0
    @State private var voiceToDelete: VoiceAsset?
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var appearance: AppAppearancePreference

    init(model: VoiceStudioModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackdrop(skin: appearance.skin, imageURL: appearance.backgroundImageURL)
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            voiceCard
                            textCard
                            shapingCard
                            expressionCard
                            languageCard
                            generateCard
                            if !model.savedVoices.isEmpty { savedVoiceLibrarySection }
                            sourceActions
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 28)
                        .frame(maxWidth: 680)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: model.mostRecentlySavedVoiceID) { _, voiceID in
                        guard let voiceID else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { scrollProxy.scrollTo(voiceID, anchor: .center) }
                    }
                }
            }
            .tint(appearance.skin.accent)
            .navigationTitle("Voice Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(destination: SettingsView(model: model)) {
                        Image(systemName: "person.circle")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settingsButton")
                }
            }
            .onAppear {
                updateDefaultVoiceName()
                syncGenerationOptions()
            }
            .task { await model.restoreLocalSpeechProvider() }
            .onChange(of: model.currentReference?.asset.id) { _, newID in
                guard newID != nil else { return }
                voiceNameWasEdited = false
                updateDefaultVoiceName()
            }
            .onChange(of: locale.identifier) { _, _ in updateDefaultVoiceName() }
            .onChange(of: model.savedVoices.map(\.id)) { _, _ in syncGenerationOptions() }
            .onChange(of: generationVoice) { _, _ in syncGenerationOptions() }
            .confirmationDialog("Delete Voice?", isPresented: Binding(
                get: { voiceToDelete != nil }, set: { if !$0 { voiceToDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let voiceToDelete { model.deleteSavedVoice(id: voiceToDelete.id) }
                    voiceToDelete = nil
                }
                Button("Cancel", role: .cancel) { voiceToDelete = nil }
            } message: {
                Text("This voice and its saved reference audio will be removed.")
            }
        }
    }

    private var voiceCard: some View {
        StudioCard(title: "Voice", symbol: "person.wave.2") {
            Picker("Voice", selection: $generationVoice) {
                Text("System Voice").tag(VoiceSelection.systemDefault)
                ForEach(model.savedVoices) { voice in
                    Text(voice.name).tag(VoiceSelection.saved(voice.id))
                }
            }
            .accessibilityIdentifier("generationVoicePicker")
            if case .saved = generationVoice, !model.isLocalSpeechReady {
                Label("Local voice generation is not ready.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var textCard: some View {
        StudioCard(title: "Text", symbol: "text.alignleft") {
            TextField("Enter text for your voice", text: $generationText, axis: .vertical)
                .lineLimit(3...7)
                .accessibilityIdentifier("generationTextField")
        }
    }

    private var shapingCard: some View {
        let capabilities = model.capabilities(for: generationVoice)
        return StudioCard(title: "Shaping", symbol: "slider.horizontal.3") {
            VStack(spacing: 14) {
                if capabilities.status(for: .pitch) == .supported {
                    LabeledContent("Pitch", value: "\(Int(pitch)) cents")
                    Slider(value: $pitch, in: -1200...1200, step: 50)
                        .accessibilityIdentifier("pitchSlider")
                }
                Text("Voice character controls will appear when a supported capability is available.")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                unavailableShapeLabels(capabilities: capabilities)
            }
        }
    }

    @ViewBuilder
    private func unavailableShapeLabels(capabilities: CapabilityProfile) -> some View {
        let unavailable = VoiceShape.allCases.filter { capabilities.shaping[$0] == nil || capabilities.shaping[$0] == .unsupported }
        if !unavailable.isEmpty {
            Text("Bright · Deep · Soft · Powerful · Youthful · Mature · Thin · Clear · Rough")
                .font(.caption).foregroundStyle(.tertiary)
                .accessibilityLabel("Voice shaping presets unavailable")
        }
    }

    private var expressionCard: some View {
        let capabilities = model.capabilities(for: generationVoice)
        return StudioCard(title: "Expression", symbol: "waveform") {
            let supported = VoiceExpression.allCases.filter { capabilities.expressions[$0] == .supported || capabilities.expressions[$0] == .approximate }
            if capabilities.status(for: .speed) == .supported {
                LabeledContent("Pace", value: speed.formatted(.number.precision(.fractionLength(2))) + "×")
                Slider(value: $speed, in: 0.5...2, step: 0.05)
                    .accessibilityIdentifier("speedSlider")
            }
            if supported.isEmpty {
                Text("Expression controls will appear when a supported capability is available.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Lively · Melancholic · Serious · Gentle · Excited · Calm · Angry · Whisper")
                    .font(.caption).foregroundStyle(.tertiary)
                    .accessibilityLabel("Expression presets unavailable")
            }
        }
    }

    private var languageCard: some View {
        let languages = model.availableLanguages(for: generationVoice)
        let accents = model.availableAccents(for: generationVoice, language: generationLanguage)
        return StudioCard(title: "Language & Accent", symbol: "globe") {
            Picker("Language", selection: $generationLanguage) {
                ForEach(languages, id: \.self) { language in
                    Text(languageDisplayName(language)).tag(language)
                }
            }
            .accessibilityIdentifier("speechLanguagePicker")
            if !accents.isEmpty {
                Picker("Accent", selection: Binding(
                    get: { generationAccent ?? accents.first ?? generationLanguage },
                    set: { generationAccent = $0 }
                )) {
                    ForEach(accents, id: \.self) { accent in Text(accentDisplayName(accent)).tag(accent) }
                }
                .accessibilityIdentifier("speechAccentPicker")
            }
        }
    }

    private var generateCard: some View {
        StudioCard(title: "Preview", symbol: "play.circle") {
            Button {
                Task {
                    await model.generateSpeech(text: generationText, voice: generationVoice,
                                               language: generationLanguage, accent: generationAccent,
                                               speed: speed, pitch: pitch)
                }
            } label: {
                Label(model.isGeneratingSpeech ? "Generating…" : "Generate", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canGenerate(text: generationText, voice: generationVoice, language: generationLanguage) || model.isGeneratingSpeech)
            .accessibilityIdentifier("generateSpeechButton")

            if model.generatedAudio != nil {
                HStack {
                    Button("Play generated speech") { model.playGeneratedAudio() }
                        .disabled(model.isGeneratingSpeech)
                    Spacer()
                    if model.generatedAudio?.persistenceState == .temporary {
                        Button("Save Audio") { model.saveGeneratedAudio() }.disabled(model.isGeneratingSpeech)
                    } else {
                        Label("Audio saved", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("generatedAudioControls")
            }
            Text(LocalizedStringKey(model.statusMessage))
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("voiceStatus")
        }
    }

    private var sourceActions: some View {
        StudioCard(title: "Create Voice", symbol: "mic") {
            HStack {
                Button(model.isRecording ? "Stop recording" : (model.isRequestingPermission ? "Requesting microphone…" : "Record")) {
                    if model.isRecording { model.stopRecording() }
                    else { Task { await model.startRecording() } }
                }
                .tint(model.isRecording ? .red : appearance.skin.accent)
                .disabled(model.isRequestingPermission && !model.isRecording)
                .accessibilityIdentifier("recordButton")
                Spacer()
                ImportAudioButton(model: model)
            }
            if model.isRecording {
                Label("Recording in progress", systemImage: "record.circle.fill")
                    .foregroundStyle(.red).accessibilityIdentifier("recordingState")
            }
            if model.microphonePermissionDenied {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }.accessibilityIdentifier("microphoneSettingsButton")
            }
            if let reference = model.currentReference {
                Divider()
                Label("Current Reference", systemImage: "waveform")
                    .font(.headline).accessibilityIdentifier("currentReferenceState")
                HStack(spacing: 4) {
                    Text("Ready ·")
                    Text(sourceLocalizationKey(for: reference.source))
                }.font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Play") { model.playCurrentAudio() }.accessibilityIdentifier("playReferenceButton")
                    Button("Stop") { model.stopPlayback() }.disabled(!model.isPlaying)
                        .accessibilityIdentifier("stopPlaybackButton")
                }
                TextField("Voice Name", text: $voiceName, onEditingChanged: { editing in
                    if editing { voiceNameWasEdited = true }
                }).accessibilityIdentifier("voiceNameField")
                Button("Save Voice") { model.saveVoice(name: voiceName) }
                    .disabled(!model.canSaveVoice || voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("saveVoiceButton")
            }
        }
    }

    private var savedVoiceLibrarySection: some View {
        StudioCard(title: "My Voices", symbol: "person.2") {
            Menu {
                ForEach(SavedVoiceFilter.allCases) { filter in
                    Button { model.setSavedVoiceFilter(filter) } label: {
                        if model.savedVoiceFilter == filter {
                            Label(filterLocalizationKey(for: filter), systemImage: "checkmark")
                        } else { Text(filterLocalizationKey(for: filter)) }
                    }
                }
            } label: {
                Label(filterLocalizationKey(for: model.savedVoiceFilter), systemImage: "line.3.horizontal.decrease")
            }.accessibilityIdentifier("savedVoiceFilterMenu")

            if model.pagedSavedVoices.isEmpty { Text("No voices in this filter.").foregroundStyle(.secondary) }
            ForEach(model.pagedSavedVoices) { voice in savedVoiceRow(voice) }
            if model.savedVoicePageCount > 1 {
                HStack {
                    Button("Previous") { model.setSavedVoicePage(model.savedVoicePage - 1) }
                        .disabled(model.savedVoicePage == 0)
                    Spacer()
                    Text("\(model.savedVoicePage + 1) / \(model.savedVoicePageCount)")
                        .accessibilityIdentifier("savedVoicePageState")
                    Spacer()
                    Button("Next") { model.setSavedVoicePage(model.savedVoicePage + 1) }
                        .disabled(model.savedVoicePage >= model.savedVoicePageCount - 1)
                }
            }
        }
    }

    private func savedVoiceRow(_ voice: VoiceAsset) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(voice.name).font(.headline)
                HStack(spacing: 4) {
                    Text(sourceLocalizationKey(for: voice.sourceType))
                    Text("·")
                    Text(SavedVoiceLibrary.formattedDuration(voice.referenceAudio.duration))
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Play") { model.playVoiceReference(voice) }.labelStyle(.iconOnly)
                .accessibilityLabel("Play \(voice.name) reference")
            Button("Stop") { model.stopPlayback() }.labelStyle(.iconOnly).accessibilityLabel("Stop playback")
            Button { voiceToDelete = voice } label: { Image(systemName: "trash") }
                .labelStyle(.iconOnly).accessibilityLabel("Delete")
        }
        .padding(.vertical, 4)
        .padding(8)
        .background(model.mostRecentlySavedVoiceID == voice.id ? appearance.skin.accent.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .id(voice.id)
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
        let key = reference.source == .record ? "Recorded Voice" : "Imported Voice"
        voiceName = String(localized: String.LocalizationValue(key), locale: locale)
    }

    private func syncGenerationOptions() {
        let choices = [VoiceSelection.systemDefault] + model.savedVoices.map { VoiceSelection.saved($0.id) }
        if !choices.contains(generationVoice) { generationVoice = .systemDefault }
        let languages = model.availableLanguages(for: generationVoice)
        if !languages.contains(generationLanguage) { generationLanguage = languages.first ?? "en" }
        let accents = model.availableAccents(for: generationVoice, language: generationLanguage)
        if !accents.contains(generationAccent ?? "") { generationAccent = accents.first }
    }

    private func languageDisplayName(_ language: String) -> String {
        locale.localizedString(forIdentifier: language) ?? language
    }

    private func accentDisplayName(_ accent: String) -> String {
        locale.localizedString(forIdentifier: accent) ?? accent
    }
}

private struct StudioCard<Content: View>: View {
    @EnvironmentObject private var appearance: AppAppearancePreference
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.skin.material, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.42), lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
    }
}

private struct StudioBackdrop: View {
    let skin: AppSkin
    let imageURL: URL?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: skin.backdrop, startPoint: .topLeading, endPoint: .bottomTrailing)
                if let imageURL, let image = UIImage(contentsOfFile: imageURL.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.24)], startPoint: .top, endPoint: .bottom)
                }
            }
            .ignoresSafeArea()
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: VoiceStudioModel
    @EnvironmentObject private var languagePreference: AppLanguagePreference
    @EnvironmentObject private var appearance: AppAppearancePreference
    @State private var selectedBackground: PhotosPickerItem?
    @State private var backgroundError: String?
    @State private var isSpeechComponentImporterPresented = false

    var body: some View {
        ZStack {
            StudioBackdrop(skin: appearance.skin, imageURL: appearance.backgroundImageURL)
            Form {
                Section("Account") {
                    NavigationLink(destination: AccountPlaceholderView()) {
                        Label("Account", systemImage: "person.circle")
                        Text("Not signed in").foregroundStyle(.secondary)
                    }.accessibilityIdentifier("accountPlaceholderLink")
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
                Section("Language") {
                    Picker("App Language", selection: Binding(
                        get: { languagePreference.language }, set: { languagePreference.set($0) }
                    )) {
                        ForEach(AppLanguage.allCases) { language in Text(language.displayName).tag(language) }
                    }.accessibilityIdentifier("appLanguagePicker")
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
                Section("Appearance") {
                    Picker("App Skin", selection: Binding(
                        get: { appearance.skin }, set: { appearance.setSkin($0) }
                    )) {
                        ForEach(AppSkin.allCases) { skin in Text(skin.displayName).tag(skin) }
                    }.accessibilityIdentifier("appSkinPicker")
                    PhotosPicker(selection: $selectedBackground, matching: .images) {
                        Label("Replace Background", systemImage: "photo")
                    }.accessibilityIdentifier("replaceBackgroundButton")
                    if appearance.backgroundImageURL != nil {
                        Button("Reset Background", role: .destructive) { appearance.clearBackgroundImage() }
                    }
                    if let backgroundError { Text(backgroundError).font(.footnote).foregroundStyle(.red) }
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
                Section("Developer Tools") {
                    Button(model.isInstallingLocalSpeech ? "Loading…" :
                           (model.isLocalSpeechReady ? "Local speech is ready." : "Import local speech component")) {
                        isSpeechComponentImporterPresented = true
                    }
                    .disabled(model.isInstallingLocalSpeech || model.isGeneratingSpeech)
                    .accessibilityIdentifier("speechComponentImportButton")
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
        }
        .tint(appearance.skin.accent)
        .navigationTitle("Settings")
        .fileImporter(isPresented: $isSpeechComponentImporterPresented,
                      allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let folder = urls.first else { return }
                Task { await model.installLocalSpeechResource(from: folder) }
            case .failure(let error): model.report(error)
            }
        }
        .task(id: selectedBackground) {
            guard let selectedBackground else { return }
            do {
                guard let data = try await selectedBackground.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let jpeg = image.jpegData(compressionQuality: 0.9) else {
                    backgroundError = "Could not use this image. Please choose another."
                    return
                }
                try appearance.saveBackgroundImage(jpeg)
                backgroundError = nil
            } catch { backgroundError = "Could not use this image. Please choose another." }
        }
    }
}

private struct AccountPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Label("Not signed in", systemImage: "person.circle").font(.headline)
            Text("Sign in will be available after the shared Fireseed account system is integrated.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding().navigationTitle("Account")
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
                case .success(let urls): if let url = urls.first { model.importAudio(from: url) }
                case .failure(let error): model.report(error)
                }
            }
    }
}
