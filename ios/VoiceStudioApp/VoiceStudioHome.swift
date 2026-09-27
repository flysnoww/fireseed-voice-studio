import PhotosUI
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoiceStudioCore

struct VoiceStudioHome: View {
    private enum InputField: Hashable { case speechText, voiceName }

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
    @State private var textInputFrames: [String: CGRect] = [:]
    @FocusState private var focusedInput: InputField?
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var appearance: AppAppearancePreference

    init(model: VoiceStudioModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackdrop(skin: appearance.skin, imageURL: appearance.backgroundImageURL)
                    .onTapGesture { focusedInput = nil }
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            voiceCard
                            textCard
                            shapingCard
                            expressionCard
                            languageCard
                            generateCard
                            developerDiagnosticsCard
                            if !model.savedVoices.isEmpty { savedVoiceLibrarySection }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.mostRecentlySavedVoiceID) { _, voiceID in
                        guard let voiceID else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { scrollProxy.scrollTo(voiceID, anchor: .center) }
                    }
                }
            }
            .coordinateSpace(name: "voiceStudioRoot")
            .onPreferenceChange(VoiceInputFramesKey.self) { textInputFrames = $0 }
            .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("voiceStudioRoot")).onEnded { tap in
                guard focusedInput != nil,
                      KeyboardDismissalPolicy.shouldDismiss(tapLocation: tap.location,
                                                           inputFrames: Array(textInputFrames.values)) else { return }
                focusedInput = nil
            })
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
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedInput = nil }
                }
            }
            .onAppear {
                updateDefaultVoiceName()
                syncGenerationOptions()
                updateDiagnosticContext()
            }
            .task {
                await model.restoreLocalSpeechProvider()
                await model.refreshTinyLocalModelState()
            }
            .onChange(of: model.currentReference?.asset.id) { _, newID in
                guard newID != nil else { return }
                voiceNameWasEdited = false
                updateDefaultVoiceName()
            }
            .onChange(of: locale.identifier) { _, _ in updateDefaultVoiceName() }
            .onChange(of: model.savedVoices.map(\.id)) { _, _ in syncGenerationOptions(); updateDiagnosticContext() }
            .onChange(of: generationVoice) { _, _ in
                focusedInput = nil
                syncGenerationOptions()
                updateDiagnosticContext()
            }
            .onChange(of: generationLanguage) { _, _ in focusedInput = nil; updateDiagnosticContext() }
            .onChange(of: generationAccent) { _, _ in updateDiagnosticContext() }
            .onChange(of: generationText) { _, _ in updateDiagnosticContext() }
            .onChange(of: model.currentReference?.asset.id) { _, _ in updateDiagnosticContext() }
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
                Text("Local Voice").tag(VoiceSelection.tinyLocal)
                ForEach(model.savedVoices) { voice in
                    Text(voice.name).tag(VoiceSelection.saved(voice.id))
                }
            }
            .accessibilityIdentifier("generationVoicePicker")
            HStack {
                Button("Record") {
                    focusedInput = nil
                    if model.isRecording { model.stopRecording() }
                    else { Task { await model.startRecording() } }
                }
                .tint(model.isRecording ? .red : appearance.skin.accent)
                .disabled(model.isRequestingPermission && !model.isRecording)
                .accessibilityIdentifier("recordButton")
                Spacer()
                ImportAudioButton(model: model, onChoose: { focusedInput = nil })
            }
            if model.isRecording {
                Label("Recording in progress", systemImage: "record.circle.fill")
                    .foregroundStyle(.red).accessibilityIdentifier("recordingState")
            }
            if model.microphonePermissionDenied {
                Button("Open Settings") {
                    focusedInput = nil
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
                })
                .focused($focusedInput, equals: .voiceName)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: VoiceInputFramesKey.self,
                                           value: ["voiceName": geometry.frame(in: .named("voiceStudioRoot"))])
                })
                .accessibilityIdentifier("voiceNameField")
                Button("Save Voice") {
                    focusedInput = nil
                    model.saveVoice(name: voiceName)
                    if let id = model.mostRecentlySavedVoiceID { generationVoice = .saved(id) }
                }
                .disabled(!model.canSaveVoice || voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("saveVoiceButton")
            }
            if case .saved = generationVoice {
                prepareVoiceButton
            }
            if case .saved = generationVoice, !model.isLocalSpeechReady {
                Label("Local voice generation is not ready.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var prepareVoiceButton: some View {
        let state = model.preparationState(for: generationVoice)
        let buttonTitle: LocalizedStringKey = switch state {
        case .none: "Confirm Voice"
        case .preparing: "Recognizing voice…"
        case .ready: "Voice Ready"
        case .failed: "Preparation failed · Retry"
        }
        let buttonTint: Color = switch state {
        case .ready: .green
        case .failed: .orange
        case .none, .preparing: appearance.skin.accent
        }
        Button {
            focusedInput = nil
            Task { await model.prepareVoice(generationVoice, language: generationLanguage) }
        } label: {
            HStack {
                if state == .preparing { ProgressView().controlSize(.small) }
                if state == .ready { Image(systemName: "checkmark.circle.fill") }
                Text(buttonTitle)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(buttonTint)
        .disabled(!model.isLocalSpeechReady || state == .preparing || model.isGeneratingSpeech)
        .accessibilityIdentifier("prepareVoiceButton")
    }

    private var textCard: some View {
        StudioCard(title: "Text", symbol: "text.alignleft") {
            TextField("Enter text for your voice", text: $generationText, axis: .vertical)
                .lineLimit(3...7)
                .focused($focusedInput, equals: .speechText)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: VoiceInputFramesKey.self,
                                           value: ["speechText": geometry.frame(in: .named("voiceStudioRoot"))])
                })
                .accessibilityIdentifier("generationTextField")
        }
    }

    private var shapingCard: some View {
        let capabilities = model.capabilities(for: generationVoice)
        return StudioCard(title: "Shaping", symbol: "slider.horizontal.3") {
            VStack(spacing: 14) {
                if capabilities.status(for: .pitch) == .supported {
                    LabeledContent("Pitch", value: "\(Int(pitch)) cents")
                    Slider(value: $pitch, in: -1200...1200, step: 50, onEditingChanged: { _ in focusedInput = nil })
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
                Slider(value: $speed, in: 0.5...2, step: 0.05, onEditingChanged: { _ in focusedInput = nil })
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
                focusedInput = nil
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

    private var developerDiagnosticsCard: some View {
        #if DEBUG || VOICE_STUDIO_DEVELOPER_DIAGNOSTICS
        StudioCard(title: "Developer Diagnostics", symbol: "stethoscope") {
            DisclosureGroup("调试状态 / Developer Diagnostics") {
                let snapshot = model.diagnostics.snapshot
                VStack(alignment: .leading, spacing: 6) {
                    diagnosticLine("Provider", snapshot.provider)
                    diagnosticLine("Renderer", snapshot.rendererID ?? "--")
                    diagnosticLine("Pack", snapshot.pack + (snapshot.packID.map { " · \($0)" } ?? ""))
                    diagnosticLine("Required files", snapshot.packFilesFound.joined(separator: ", ").isEmpty ? "--" : snapshot.packFilesFound.joined(separator: ", "))
                    diagnosticLine("Runtime", snapshot.runtime)
                    diagnosticLine("Renderer load", snapshot.rendererLoadDurationMilliseconds.map { "\($0) ms" } ?? "--")
                    diagnosticLine("Model folder", snapshot.runtimeModelLocation ?? "--")
                    diagnosticLine("Backend", snapshot.backend)
                    diagnosticLine("Voice", snapshot.voice)
                    diagnosticLine("Reference", snapshot.reference)
                    diagnosticLine("Language", snapshot.language)
                    diagnosticLine("Accent", snapshot.accent ?? "--")
                    diagnosticLine("Request", snapshot.request)
                    diagnosticLine("Generate", snapshot.generation)
                    diagnosticLine("Generate time", snapshot.generationDurationMilliseconds.map { "\($0) ms" } ?? "--")
                    diagnosticLine("Renderer inference", snapshot.rendererGenerationDurationMilliseconds.map { "\($0) ms" } ?? "--")
                    diagnosticLine("RTF", snapshot.realTimeFactor.map { String(format: "%.2f", $0) } ?? "--")
                    diagnosticLine("Output", snapshot.outputFileName.map { "\($0) · \(snapshot.outputDuration.map { String(format: "%.2f s", $0) } ?? "--")" } ?? "none")
                    Divider()
                    ForEach(model.diagnostics.stages, id: \.stage) { stage in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(stage.stage.rawValue)
                                Spacer()
                                Text(stage.state.rawValue)
                                if let duration = stage.durationMilliseconds { Text("\(duration) ms") }
                            }.font(.caption.monospaced())
                            if let friendly = stage.friendlyError { Text("Friendly: \(friendly)").font(.caption) }
                            if let domain = stage.errorDomain, let code = stage.errorCode {
                                Text("Code: \(domain) / \(code)").font(.caption.monospaced())
                            }
                            if let raw = stage.underlyingError { Text("Raw: \(raw)").font(.caption).textSelection(.enabled) }
                            if let operation = stage.operation { Text("Operation: \(operation)").font(.caption.monospaced()) }
                            if let file = stage.file { Text("File: \(file)").font(.caption.monospaced()) }
                            if let expected = stage.expected { Text("Expected: \(expected)").font(.caption).textSelection(.enabled) }
                            if let actual = stage.actual { Text("Actual: \(actual)").font(.caption).textSelection(.enabled) }
                        }
                    }
                    HStack {
                        Button("Copy Diagnostics") { UIPasteboard.general.string = model.diagnostics.exportText() }
                        Spacer()
                        Button("Clear") { model.diagnostics.clear() }
                    }
                    .font(.caption)
                }
                .padding(.top, 8)
            }
            .accessibilityIdentifier("developerDiagnosticsDisclosure")
        }
        #else
        EmptyView()
        #endif
    }

    private func diagnosticLine(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.caption.monospaced())
    }

    private func updateDiagnosticContext() {
        model.updateDiagnosticContext(voice: generationVoice, language: generationLanguage,
                                      accent: generationAccent,
                                      hasText: !generationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                      hasCurrentReference: model.currentReference != nil)
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
        let choices = [VoiceSelection.systemDefault, .tinyLocal] + model.savedVoices.map { VoiceSelection.saved($0.id) }
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
                }
            }
            .ignoresSafeArea()
        }
    }
}

private struct SettingsView: View {
    private let backgroundLogger = Logger(subsystem: "com.fireseed.voicestudio", category: "background-import")
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
                Section("Local Voice") {
                    if model.isTinyLocalModelReady {
                        Label("Local voice is ready", systemImage: "checkmark.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Local voice data downloads the first time you generate with Local Voice.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button(model.isDeletingTinyLocalModel ? "Removing…" : "Remove Local Voice Data", role: .destructive) {
                        Task { await model.deleteTinyLocalModel() }
                    }
                    .disabled(!model.isTinyLocalModelReady || model.isDeletingTinyLocalModel || model.isGeneratingSpeech)
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
            case .failure(let error): model.reportLocalSpeechImportError(error)
            }
        }
        .task(id: selectedBackground) {
            guard let selectedBackground else { return }
            let sourceTypes = selectedBackground.supportedContentTypes.map(\.identifier).joined(separator: ", ")
            backgroundLogger.info("Background import source content type: \(sourceTypes, privacy: .public)")
            do {
                guard let data = try await selectedBackground.loadTransferable(type: Data.self), !data.isEmpty else {
                    backgroundError = "Could not use this image. Please choose another."
                    backgroundLogger.error("Background import failed at transfer: no image data")
                    return
                }
                try appearance.saveBackgroundImage(data)
                backgroundError = nil
            } catch {
                backgroundError = "Could not use this image. Please choose another."
                let failure = error as? BackgroundImageNormalizer.Failure
                backgroundLogger.error("Background import failed at \(failure?.stage ?? "persistence", privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
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
    var onChoose: () -> Void = {}
    @State private var isImporterPresented = false

    var body: some View {
        Button("Import") { onChoose(); isImporterPresented = true }
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

enum KeyboardDismissalPolicy {
    static func shouldDismiss(tapLocation: CGPoint, inputFrames: [CGRect]) -> Bool {
        !inputFrames.contains { $0.insetBy(dx: -6, dy: -6).contains(tapLocation) }
    }
}

private struct VoiceInputFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
