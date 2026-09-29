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
    @State private var brightness = 0.0
    @State private var clarity = 0.0
    @State private var softness = 0.0
    @State private var personalVoiceRefresh = 0
    @State private var useSystemVoiceConverter = false
    @State private var converterSourceVoiceIdentifier: String?
    @State private var voiceToDelete: VoiceAsset?
    @State private var generatedAudioToDelete: AudioAsset?
    @State private var voiceToEdit: VoiceAsset?
    @State private var audioToEdit: AudioAsset?
    @State private var isSavedVoicePickerPresented = false
    @State private var isSystemVoicePickerPresented = false
    @State private var isGeneratedAudioLibraryPresented = false
    @State private var pendingVoiceName: String?
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
                            libraryEntryCard
                            textCard
                            shapingCard
                            expressionCard
                            languageCard
                            generateCard
                            developerDiagnosticsCard
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
            .toolbarBackground(.hidden, for: .navigationBar)
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
                if generationVoice.savedVoiceID == nil { useSystemVoiceConverter = false }
                syncGenerationOptions()
                updateDiagnosticContext()
                Task { await model.activateVoice(generationVoice) }
            }
            .onChange(of: useSystemVoiceConverter) { _, enabled in
                guard enabled, generationVoice.savedVoiceID != nil else { return }
                Task { await model.prepareOpenVoiceTarget(generationVoice) }
                syncGenerationOptions()
            }
            .onChange(of: generationLanguage) { _, _ in focusedInput = nil; updateDiagnosticContext() }
            .onChange(of: generationAccent) { _, _ in updateDiagnosticContext() }
            .onChange(of: generationText) { _, _ in updateDiagnosticContext() }
            .onChange(of: model.currentReference?.asset.id) { _, _ in updateDiagnosticContext() }
            .modifier(VoiceLibraryPresentationModifier(
                voiceToDelete: $voiceToDelete,
                generatedAudioToDelete: $generatedAudioToDelete,
                voiceToEdit: $voiceToEdit,
                audioToEdit: $audioToEdit,
                isSystemVoicePickerPresented: $isSystemVoicePickerPresented,
                isGeneratedAudioLibraryPresented: $isGeneratedAudioLibraryPresented,
                generationVoice: $generationVoice,
                systemVoicePicker: { AnyView(systemVoicePicker) },
                generatedAudioLibrary: { AnyView(generatedAudioLibrary) },
                deleteVoice: { model.deleteSavedVoice(id: $0) },
                deleteAudio: { model.deleteGeneratedAudio(id: $0) },
                playVoice: { model.playVoiceReference($0) },
                playAudio: { model.playAudioAsset($0) },
                stopPlayback: { model.stopPlayback() },
                renameVoice: { model.renameSavedVoice(id: $0, name: $1) },
                favoriteVoice: { model.setSavedVoiceFavorite(id: $0, isFavorite: $1) },
                renameAudio: { model.renameGeneratedAudio(id: $0, name: $1) },
                favoriteAudio: { model.setGeneratedAudioFavorite(id: $0, isFavorite: $1) },
                shareURL: { model.managedURL(for: $0) }
            ))
        }
    }


    private var voiceCard: some View {
        StudioCard(title: "Voice", symbol: "person.wave.2") {
            LabeledContent("Current voice", value: selectedVoiceName)
            Menu {
                Button("System Default") { generationVoice = .systemDefault }
                Button("Choose System Voice…") { isSystemVoicePickerPresented = true }
                Button("Local Voice") { generationVoice = .tinyLocal }
            } label: {
                Label("Built-in Voices", systemImage: "chevron.down.circle")
            }
            .accessibilityIdentifier("generationVoicePicker")
            HStack {
                Button {
                    focusedInput = nil
                    isSavedVoicePickerPresented = true
                } label: {
                    Label("My Voices", systemImage: "person.2")
                }
                .accessibilityIdentifier("myVoicesButton")
                Button {
                    focusedInput = nil
                    isSystemVoicePickerPresented = true
                } label: { Label("System Voices", systemImage: "waveform") }
                Spacer()
                Button {
                    focusedInput = nil
                    if model.isRecording { model.stopRecording() }
                    else { Task { await model.startRecording() } }
                } label: {
                    Label(model.isRecording ? "Stop Recording" : "Record New Voice",
                          systemImage: model.isRecording ? "stop.circle" : "record.circle")
                }
                .tint(model.isRecording ? .red : appearance.skin.accent)
                .disabled(model.isRequestingPermission && !model.isRecording)
                .accessibilityIdentifier("recordNewVoiceButton")
            }
            if generationVoice.savedVoiceID != nil {
                Picker("Voice method", selection: $useSystemVoiceConverter) {
                    Text("Quality Clone").tag(false)
                    Text("System Voice Conversion").tag(true)
                }
                .disabled((!model.isOpenVoicePackReady && !useSystemVoiceConverter) ||
                          model.isInstallingOpenVoicePack || model.isDeletingOpenVoicePack ||
                          model.isPreparingOpenVoiceTarget || model.isGeneratingSpeech)
                .accessibilityIdentifier("voiceRendererPicker")
                if useSystemVoiceConverter {
                    Picker("Source System Voice", selection: $converterSourceVoiceIdentifier) {
                        Text("System Default").tag(Optional<String>.none)
                        ForEach(SystemVoiceCatalog.voices(AVSpeechSynthesisVoice.speechVoices()), id: \.identifier) { voice in
                            Text("\(voice.name) · \(languageDisplayName(voice.language))")
                                .tag(Optional(voice.identifier))
                        }
                    }
                    .accessibilityIdentifier("converterSourceVoicePicker")
                } else if !model.isOpenVoicePackReady {
                    Text("Install the optional voice converter pack in Settings to use this method.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ImportAudioButton(model: model, onChoose: { focusedInput = nil }, onImported: { url in
                let candidateName = url.deletingPathExtension().lastPathComponent
                let name = candidateName.isEmpty ? String(localized: "Imported Voice", locale: locale) : candidateName
                pendingVoiceName = name
                voiceName = name
                voiceNameWasEdited = false
            })
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Voice Name").font(.caption).foregroundStyle(.secondary)
                    TextField("Voice Name", text: $voiceName, onEditingChanged: { editing in
                        if editing { voiceNameWasEdited = true }
                    })
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedInput, equals: .voiceName)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: VoiceInputFramesKey.self,
                                               value: ["voiceName": geometry.frame(in: .named("voiceStudioRoot"))])
                    })
                    .accessibilityHint("Editable voice name")
                    .accessibilityIdentifier("voiceNameField")
                }
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
        }
        .sheet(isPresented: $isSavedVoicePickerPresented) {
            NavigationStack {
                List {
                    if model.savedVoices.isEmpty {
                        Text("No saved voices yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.pagedSavedVoices) { voice in
                        HStack {
                            Button {
                                generationVoice = .saved(voice.id)
                                isSavedVoicePickerPresented = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(voice.name)
                                        Text("\(sourceLocalizationKey(for: voice.sourceType)) · \(SavedVoiceLibrary.formattedDuration(voice.referenceAudio.duration))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if generationVoice == .saved(voice.id) { Image(systemName: "checkmark").foregroundStyle(appearance.skin.accent) }
                                }
                            }.accessibilityIdentifier("savedVoiceChoice-\(voice.id.uuidString)")
                            Button { voiceToEdit = voice; isSavedVoicePickerPresented = false } label: {
                                Image(systemName: "info.circle")
                            }.accessibilityLabel("Edit \(voice.name)")
                            Button { voiceToDelete = voice } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Delete \(voice.name)")
                        }
                    }
                    if model.savedVoicePageCount > 1 {
                        HStack {
                            Button("Previous") { model.setSavedVoicePage(model.savedVoicePage - 1) }.disabled(model.savedVoicePage == 0)
                            Spacer(); Text("\(model.savedVoicePage + 1) / \(model.savedVoicePageCount)"); Spacer()
                            Button("Next") { model.setSavedVoicePage(model.savedVoicePage + 1) }
                                .disabled(model.savedVoicePage >= model.savedVoicePageCount - 1)
                        }
                    }
                }
                .navigationTitle("My Voices")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { isSavedVoicePickerPresented = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var libraryEntryCard: some View {
        StudioCard(title: "Libraries", symbol: "square.stack") {
            HStack {
                Button { isSavedVoicePickerPresented = true } label: {
                    Label("My Voices", systemImage: "person.2")
                }
                Spacer()
                Button { isGeneratedAudioLibraryPresented = true } label: {
                    Label("Generation History", systemImage: "waveform.path")
                }
            }
        }
    }

    private var systemVoicePicker: some View {
        NavigationStack {
            List {
                Button {
                    generationVoice = .systemDefault
                    isSystemVoicePickerPresented = false
                } label: {
                    HStack { Text("System Default"); Spacer(); if generationVoice == .systemDefault { Image(systemName: "checkmark") } }
                }
                let systemVoices = SystemVoiceCatalog.voices(AVSpeechSynthesisVoice.speechVoices())
                let personalVoices = SystemVoiceCatalog.personalVoices(systemVoices)
                if !personalVoices.isEmpty {
                    Section("Personal Voice") {
                        ForEach(personalVoices, id: \.identifier, content: systemVoiceRow)
                    }
                } else if AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .notDetermined {
                    Section("Personal Voice") {
                        Button("Enable Personal Voice") {
                            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { _ in
                                Task { @MainActor in personalVoiceRefresh += 1 }
                            }
                        }
                    }
                }
                Section("System Voices") {
                    ForEach(SystemVoiceCatalog.nonPersonalVoices(systemVoices), id: \.identifier, content: systemVoiceRow)
                }
            }
            .id(personalVoiceRefresh)
            .navigationTitle("System Voices")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { isSystemVoicePickerPresented = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func systemVoiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        Button {
            generationVoice = .systemVoice(voice.identifier)
            generationLanguage = voice.language
            generationAccent = voice.language
            isSystemVoicePickerPresented = false
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(voice.name)
                    Text(languageDisplayName(voice.language)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if generationVoice == .systemVoice(voice.identifier) { Image(systemName: "checkmark") }
            }
        }.accessibilityIdentifier("systemVoice-\(voice.identifier)")
    }

    private var generatedAudioLibrary: some View {
        NavigationStack {
            List {
                if model.pagedGeneratedAudio.isEmpty { Text("No generated audio yet.").foregroundStyle(.secondary) }
                ForEach(model.pagedGeneratedAudio) { audio in
                    Button { audioToEdit = audio; isGeneratedAudioLibraryPresented = false } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(audio.displayName).font(.headline); if audio.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) } }
                            Text("\(audio.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(SavedVoiceLibrary.formattedDuration(audio.duration)) · \(generatedSourceName(audio.sourceVoice))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let text = audio.text { Text(text).lineLimit(2).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }.accessibilityIdentifier("generatedAudio-\(audio.id.uuidString)")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { generatedAudioToDelete = audio } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                if model.generatedAudioPageCount > 1 {
                    HStack {
                        Button("Previous") { model.setGeneratedAudioPage(model.generatedAudioPage - 1) }
                            .disabled(model.generatedAudioPage == 0)
                        Spacer(); Text("\(model.generatedAudioPage + 1) / \(model.generatedAudioPageCount)"); Spacer()
                        Button("Next") { model.setGeneratedAudioPage(model.generatedAudioPage + 1) }
                            .disabled(model.generatedAudioPage >= model.generatedAudioPageCount - 1)
                    }
                }
            }
            .navigationTitle("Generation History")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { isGeneratedAudioLibraryPresented = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func generatedSourceName(_ source: GeneratedAudioVoiceSource?) -> String {
        switch source {
        case .savedVoice: String(localized: "My Voices", locale: locale)
        case .systemVoice: String(localized: "System Voice", locale: locale)
        case .tinyLocalVoice: String(localized: "Local Voice", locale: locale)
        case nil: String(localized: "Unknown Voice", locale: locale)
        }
    }

    @ViewBuilder
    private var prepareVoiceButton: some View {
        let state = model.preparationState(for: generationVoice)
        let converterReady = generationVoice.savedVoiceID == model.preparedOpenVoiceID &&
            model.hasPreparedOpenVoiceReference
        let buttonTitle: LocalizedStringKey
        if useSystemVoiceConverter {
            buttonTitle = model.isPreparingOpenVoiceTarget ? "Preparing voice…" : (converterReady ? "Voice Ready" : "Prepare Voice")
        } else {
            buttonTitle = switch state {
                case .none: "Confirm Voice"
                case .preparing: "Preparing voice…"
                case .ready: "Voice Ready"
                case .failed: "Preparation failed · Retry"
            }
        }
        let isReady = useSystemVoiceConverter ? converterReady : state == .ready
        let buttonTint: Color = isReady ? .green : appearance.skin.accent
        Button {
            focusedInput = nil
            Task {
                if useSystemVoiceConverter { await model.prepareOpenVoiceTarget(generationVoice) }
                else { await model.prepareVoice(generationVoice, language: generationLanguage) }
            }
        } label: {
            HStack {
                if state == .preparing || model.isPreparingOpenVoiceTarget { ProgressView().controlSize(.small) }
                if isReady { Image(systemName: "checkmark.circle.fill") }
                Text(buttonTitle)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(buttonTint)
        .disabled(model.isInstallingLocalSpeech || state == .preparing || model.isPreparingOpenVoiceTarget || model.isGeneratingSpeech)
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
        let capabilities = model.capabilities(for: generationVoice, usingVoiceConverter: useSystemVoiceConverter)
        return StudioCard(title: "Shaping", symbol: "slider.horizontal.3") {
            VStack(spacing: 14) {
                if capabilities.status(for: .pitch) == .supported {
                    LabeledContent("Pitch", value: "\(Int(pitch)) cents")
                    Slider(value: $pitch, in: -1200...1200, step: 50, onEditingChanged: { _ in focusedInput = nil })
                        .accessibilityIdentifier("pitchSlider")
                }
                ForEach(VoiceCapabilityVisibility.visibleShaping(in: capabilities), id: \.self) { shape in
                    switch shape {
                    case .brightness:
                        shapingControl(shape, title: "Brightness", value: $brightness, capabilities: capabilities)
                    case .clarity:
                        shapingControl(shape, title: "Clarity", value: $clarity, capabilities: capabilities)
                    case .softness:
                        shapingControl(shape, title: "Softness", value: $softness, capabilities: capabilities)
                    default: EmptyView()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func shapingControl(_ shape: VoiceShape, title: LocalizedStringKey, value: Binding<Double>,
                                capabilities: CapabilityProfile) -> some View {
        if capabilities.shaping[shape] == .supported || capabilities.shaping[shape] == .approximate {
            LabeledContent(title, value: value.wrappedValue.formatted(.number.precision(.fractionLength(1))))
            Slider(value: value, in: -1...1, step: 0.1, onEditingChanged: { _ in focusedInput = nil })
                .accessibilityIdentifier("shaping-\(shape.rawValue)-slider")
        }
    }

    private var expressionCard: some View {
        let capabilities = model.capabilities(for: generationVoice, usingVoiceConverter: useSystemVoiceConverter)
        return StudioCard(title: "Expression", symbol: "waveform") {
            let supported = VoiceCapabilityVisibility.visibleExpressions(in: capabilities)
            if capabilities.status(for: .speed) == .supported {
                LabeledContent("Pace", value: speed.formatted(.number.precision(.fractionLength(2))) + "×")
                Slider(value: $speed, in: 0.5...2, step: 0.05, onEditingChanged: { _ in focusedInput = nil })
                    .accessibilityIdentifier("speedSlider")
            }
            if !supported.isEmpty {
                Picker("Expression", selection: Binding(
                    get: { supported[0] },
                    set: { _ in focusedInput = nil }
                )) {
                    ForEach(supported, id: \.self) { expression in Text(String(describing: expression)).tag(expression) }
                }
                .accessibilityIdentifier("expressionPicker")
            } else {
                Text("Expression controls will appear when a supported capability is available.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Lively · Melancholic · Serious · Gentle · Excited · Calm · Angry · Whisper")
                    .font(.caption).foregroundStyle(.tertiary)
                    .accessibilityLabel("Expression presets unavailable")
            }
        }
    }

    private var languageCard: some View {
        let languages = model.availableLanguages(for: generationVoice, usingVoiceConverter: useSystemVoiceConverter)
        let accents = model.availableAccents(for: generationVoice, language: generationLanguage,
                                             usingVoiceConverter: useSystemVoiceConverter)
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
                    let shaping = VoiceShaping(values: [.brightness: brightness,
                                                        .clarity: clarity,
                                                        .softness: softness])
                    if useSystemVoiceConverter {
                        let sourceVoice = converterSourceVoiceIdentifier.map(VoiceSelection.systemVoice) ?? .systemDefault
                        await model.generateOpenVoiceSpeech(text: generationText, target: generationVoice,
                                                            systemSource: sourceVoice, language: generationLanguage,
                                                            accent: generationAccent, shaping: shaping,
                                                            speed: speed, pitch: pitch)
                    } else {
                        await model.generateSpeech(text: generationText, voice: generationVoice,
                                                   language: generationLanguage, accent: generationAccent,
                                                   shaping: shaping, speed: speed, pitch: pitch)
                    }
                }
            } label: {
                Label(model.isGeneratingSpeech ? "Generating…" : "Generate", systemImage: "waveform")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canGenerate(text: generationText, voice: generationVoice,
                                         language: generationLanguage,
                                         usingVoiceConverter: useSystemVoiceConverter) || model.isGeneratingSpeech)
            .accessibilityIdentifier("generateSpeechButton")

            if model.generatedAudio != nil {
                HStack {
                    Button(model.isPlaying ? "Pause" : "Play generated speech") {
                        if model.isPlaying { model.stopPlayback() } else { model.playGeneratedAudio() }
                    }
                        .disabled(model.isGeneratingSpeech)
                    Spacer()
                    if model.generatedAudio?.persistenceState == .temporary {
                        Button("Save Audio") { model.saveGeneratedAudio() }.disabled(model.isGeneratingSpeech)
                    } else {
                        Label("Audio saved", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                    if let audio = model.generatedAudio, let url = model.managedURL(for: audio) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                            .accessibilityLabel("Share generated audio")
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

    private func sourceLocalizationKey(for source: VoiceSourceType) -> LocalizedStringKey {
        switch source {
        case .record: "Recorded"
        case .imported: "Imported"
        case .random: "Random"
        case .builtIn: "Built-in"
        }
    }

    private func updateDefaultVoiceName() {
        if let pendingVoiceName, !pendingVoiceName.isEmpty {
            voiceName = pendingVoiceName
            self.pendingVoiceName = nil
            return
        }
        guard !voiceNameWasEdited, let reference = model.currentReference else { return }
        let key = reference.source == .record ? "Recorded Voice" : "Imported Voice"
        voiceName = String(localized: String.LocalizationValue(key), locale: locale)
    }

    private var selectedVoiceName: String {
        switch generationVoice {
        case .systemDefault:
            String(localized: "System Default", locale: locale)
        case .systemVoice(let identifier):
            AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == identifier })?.name
                ?? String(localized: "System Voice", locale: locale)
        case .tinyLocal:
            String(localized: "Local Voice", locale: locale)
        case .saved(let id):
            model.savedVoices.first(where: { $0.id == id })?.name ?? String(localized: "My Voices", locale: locale)
        }
    }

    private func syncGenerationOptions() {
        let systemChoices = SystemVoiceCatalog.voices(AVSpeechSynthesisVoice.speechVoices()).map {
            VoiceSelection.systemVoice($0.identifier)
        }
        let choices = [VoiceSelection.systemDefault, .tinyLocal] + systemChoices + model.savedVoices.map { VoiceSelection.saved($0.id) }
        if !choices.contains(generationVoice) { generationVoice = .systemDefault }
        let languages = model.availableLanguages(for: generationVoice, usingVoiceConverter: useSystemVoiceConverter)
        if !languages.contains(generationLanguage) { generationLanguage = languages.first ?? "en" }
        let accents = model.availableAccents(for: generationVoice, language: generationLanguage,
                                             usingVoiceConverter: useSystemVoiceConverter)
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

private struct VoiceLibraryPresentationModifier: ViewModifier {
    @Binding var voiceToDelete: VoiceAsset?
    @Binding var generatedAudioToDelete: AudioAsset?
    @Binding var voiceToEdit: VoiceAsset?
    @Binding var audioToEdit: AudioAsset?
    @Binding var isSystemVoicePickerPresented: Bool
    @Binding var isGeneratedAudioLibraryPresented: Bool
    @Binding var generationVoice: VoiceSelection
    let systemVoicePicker: () -> AnyView
    let generatedAudioLibrary: () -> AnyView
    let deleteVoice: (UUID) -> Void
    let deleteAudio: (UUID) -> Void
    let playVoice: (VoiceAsset) -> Void
    let playAudio: (AudioAsset) -> Void
    let stopPlayback: () -> Void
    let renameVoice: (UUID, String) -> Void
    let favoriteVoice: (UUID, Bool) -> Void
    let renameAudio: (UUID, String) -> Void
    let favoriteAudio: (UUID, Bool) -> Void
    let shareURL: (AudioAsset) -> URL?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Delete Voice?", isPresented: voiceDeletePresented, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let voiceToDelete { deleteVoice(voiceToDelete.id) }
                    voiceToDelete = nil
                }
                Button("Cancel", role: .cancel) { voiceToDelete = nil }
            } message: { Text("This voice and its saved reference audio will be removed.") }
            .confirmationDialog("Delete Generated Audio?", isPresented: audioDeletePresented, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let generatedAudioToDelete { deleteAudio(generatedAudioToDelete.id) }
                    generatedAudioToDelete = nil
                }
                Button("Cancel", role: .cancel) { generatedAudioToDelete = nil }
            } message: { Text("This generated audio file will be removed.") }
            .sheet(isPresented: $isSystemVoicePickerPresented, content: systemVoicePicker)
            .sheet(isPresented: $isGeneratedAudioLibraryPresented, content: generatedAudioLibrary)
            .sheet(item: $voiceToEdit) { voice in
                VoiceAssetEditor(voice: voice, selected: generationVoice == .saved(voice.id),
                                 onSelect: { generationVoice = .saved(voice.id); voiceToEdit = nil },
                                 onPlay: { playVoice(voice) }, onStop: stopPlayback,
                                 onRename: { renameVoice(voice.id, $0) },
                                 onFavorite: { favoriteVoice(voice.id, $0) },
                                 onDelete: { voiceToEdit = nil; voiceToDelete = voice })
            }
            .sheet(item: $audioToEdit) { audio in
                GeneratedAudioEditor(audio: audio, shareURL: shareURL(audio),
                                     onPlay: { playAudio(audio) }, onStop: stopPlayback,
                                     onRename: { renameAudio(audio.id, $0) },
                                     onFavorite: { favoriteAudio(audio.id, $0) },
                                     onDelete: { audioToEdit = nil; generatedAudioToDelete = audio })
            }
    }

    private var voiceDeletePresented: Binding<Bool> {
        Binding(get: { voiceToDelete != nil }, set: { if !$0 { voiceToDelete = nil } })
    }

    private var audioDeletePresented: Binding<Bool> {
        Binding(get: { generatedAudioToDelete != nil }, set: { if !$0 { generatedAudioToDelete = nil } })
    }
}

struct BackgroundImportRequestGate {
    private(set) var activeRequestID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        activeRequestID = id
        return id
    }

    func accepts(_ id: UUID) -> Bool { activeRequestID == id }

    mutating func finish(_ id: UUID) -> Bool {
        guard accepts(id) else { return false }
        activeRequestID = nil
        return true
    }

    mutating func cancel() { activeRequestID = nil }
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
    @State private var isLoadingBackground = false
    @State private var isSpeechComponentImporterPresented = false
    @State private var isOpenVoicePackImporterPresented = false
    @State private var backgroundImportTask: Task<Void, Never>?
    @State private var backgroundImportGate = BackgroundImportRequestGate()

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
                    if isLoadingBackground {
                        ProgressView("Loading…")
                    }
                    if appearance.backgroundImageURL != nil {
                        Button("Reset Background", role: .destructive) { appearance.clearBackgroundImage() }
                    }
                    if let backgroundError { Text(backgroundError).font(.footnote).foregroundStyle(.red) }
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
#if DEBUG
                Section("Background Import Diagnostics") {
                    Button("Copy Background Diagnostics") {
                        UIPasteboard.general.string = appearance.backgroundDiagnosticsText
                    }
                    Text(appearance.backgroundDiagnostics.last?.exportLine ?? "No background imports recorded.")
                        .font(.caption.monospaced()).textSelection(.enabled)
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
#endif
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
                Section("Experimental Voice Converter") {
                    Label(model.isOpenVoicePackReady ? "Optional pack validated" : "Optional pack not installed",
                          systemImage: model.isOpenVoicePackReady ? "checkmark.circle" : "arrow.down.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(model.isInstallingOpenVoicePack ? "Validating…" : "Install or Replace OpenVoice Pack") {
                        isOpenVoicePackImporterPresented = true
                    }.disabled(model.isInstallingOpenVoicePack || model.isGeneratingSpeech || model.isPreparingOpenVoiceTarget)
                    Button("Validate OpenVoice Pack") { Task { await model.refreshOpenVoicePackState() } }
                        .disabled(model.isInstallingOpenVoicePack || model.isPreparingOpenVoiceTarget)
                    Button(model.isDeletingOpenVoicePack ? "Removing…" : "Remove OpenVoice Pack", role: .destructive) {
                        Task { await model.deleteOpenVoicePack() }
                    }.disabled(!model.isOpenVoicePackReady || model.isDeletingOpenVoicePack || model.isGeneratingSpeech || model.isPreparingOpenVoiceTarget)
                    Text("Experimental voice conversion. Device quality and performance still need validation.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Use an approximately 10-second saved voice reference for this experimental converter.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
        }
        .tint(appearance.skin.accent)
        .navigationTitle("Settings")
        .toolbarBackground(.hidden, for: .navigationBar)
        .fileImporter(isPresented: $isSpeechComponentImporterPresented,
                      allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let folder = urls.first else { return }
                Task { await model.installLocalSpeechResource(from: folder) }
            case .failure(let error): model.reportLocalSpeechImportError(error)
            }
        }
        .fileImporter(isPresented: $isOpenVoicePackImporterPresented,
                      allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let folder = urls.first else { return }
                Task { await model.installOpenVoicePack(from: folder) }
            case .failure:
                model.statusMessage = "OpenVoice pack could not be imported."
            }
        }
        .task { await model.refreshOpenVoicePackState() }
        .onChange(of: selectedBackground) { _, item in
            guard let item else { return }
            backgroundImportTask?.cancel()
            let requestID = backgroundImportGate.begin()
            selectedBackground = nil
            isLoadingBackground = true
            let sourceTypes = item.supportedContentTypes.map(\.identifier).joined(separator: ", ")
            let sourceType = item.supportedContentTypes.first?.identifier
            backgroundImportTask = Task { @MainActor in
                appearance.recordBackgroundDiagnostic(stage: "pickerSelection", succeeded: true,
                                                        sourceContentType: sourceType, requestID: requestID)
                backgroundLogger.info("Background import source content type: \(sourceTypes, privacy: .public)")
                let loadStarted = ProcessInfo.processInfo.systemUptime
                do {
                    let fileTransfer: BackgroundPhotoFileTransfer?
                    do {
                        fileTransfer = try await item.loadTransferable(type: BackgroundPhotoFileTransfer.self)
                    } catch {
                        fileTransfer = nil
                        appearance.recordBackgroundDiagnostic(stage: "fileRepresentationFallback", succeeded: false,
                                                              sourceContentType: sourceType, error: error, requestID: requestID)
                    }
                    let data: Data?
                    if let fileTransfer { data = fileTransfer.data }
                    else { data = try await item.loadTransferable(type: Data.self) }
                    let duration = max(0, Int((ProcessInfo.processInfo.systemUptime - loadStarted) * 1000))
                    guard let data, !data.isEmpty else { throw BackgroundPhotoTransferError.empty }
                    try Task.checkCancellation()
                    guard backgroundImportGate.accepts(requestID) else { return }
                    appearance.recordBackgroundDiagnostic(stage: "loadTransferable", succeeded: true,
                                                          sourceContentType: sourceType, durationMilliseconds: duration,
                                                          requestID: requestID)
                    let metadata = BackgroundImageMetadata(contentType: sourceType, sourceByteSize: data.count)
                    appearance.recordBackgroundDiagnostic(stage: "readData", succeeded: true,
                                                          sourceContentType: sourceType, metadata: metadata, requestID: requestID)
                    appearance.recordBackgroundDiagnostic(stage: "detectType", succeeded: true,
                                                          sourceContentType: sourceType, metadata: metadata, requestID: requestID)
                    guard backgroundImportGate.accepts(requestID) else { return }
                    try appearance.saveBackgroundImage(data, sourceContentType: sourceType, requestID: requestID)
                    guard backgroundImportGate.finish(requestID) else { return }
                    backgroundError = nil
                    isLoadingBackground = false
                } catch {
                    guard backgroundImportGate.finish(requestID) else { return }
                    if !Task.isCancelled {
                        appearance.recordBackgroundDiagnostic(stage: "loadTransferable", succeeded: false,
                                                              sourceContentType: sourceType, error: error,
                                                              durationMilliseconds: max(0, Int((ProcessInfo.processInfo.systemUptime - loadStarted) * 1000)),
                                                              requestID: requestID)
                        backgroundError = "Could not use this image. Please choose another."
                    }
                    isLoadingBackground = false
                }
            }
        }
        .onDisappear {
            backgroundImportTask?.cancel()
            backgroundImportGate.cancel()
            isLoadingBackground = false
        }
    }
}

private enum BackgroundPhotoTransferError: Error {
    case empty
}

private struct BackgroundPhotoFileTransfer: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            BackgroundPhotoFileTransfer(data: try Data(contentsOf: received.file))
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

private struct VoiceAssetEditor: View {
    let voice: VoiceAsset
    let selected: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void
    let onStop: () -> Void
    let onRename: (String) -> Void
    let onFavorite: (Bool) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(voice: VoiceAsset, selected: Bool, onSelect: @escaping () -> Void,
         onPlay: @escaping () -> Void, onStop: @escaping () -> Void,
         onRename: @escaping (String) -> Void, onFavorite: @escaping (Bool) -> Void,
         onDelete: @escaping () -> Void) {
        self.voice = voice; self.selected = selected; self.onSelect = onSelect
        self.onPlay = onPlay; self.onStop = onStop; self.onRename = onRename
        self.onFavorite = onFavorite; self.onDelete = onDelete
        _name = State(initialValue: voice.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Voice Name", text: $name)
                    LabeledContent("Source", value: voice.sourceType.rawValue.capitalized)
                    LabeledContent("Duration", value: SavedVoiceLibrary.formattedDuration(voice.referenceAudio.duration))
                    LabeledContent("Saved", value: voice.savedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section {
                    HStack {
                        Button("Play") { onPlay() }
                        Button("Stop") { onStop() }
                        Button(selected ? "Selected" : "Select Voice") { onSelect() }
                    }
                    Toggle("Favorite", isOn: Binding(get: { voice.isFavorite }, set: onFavorite))
                }
                Section {
                    Button("Save Changes") { onRename(name); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Delete Voice…", role: .destructive) { onDelete() }
                }
            }
            .navigationTitle("Voice Details")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct GeneratedAudioEditor: View {
    let audio: AudioAsset
    let shareURL: URL?
    let onPlay: () -> Void
    let onStop: () -> Void
    let onRename: (String) -> Void
    let onFavorite: (Bool) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(audio: AudioAsset, shareURL: URL?, onPlay: @escaping () -> Void, onStop: @escaping () -> Void,
         onRename: @escaping (String) -> Void, onFavorite: @escaping (Bool) -> Void,
         onDelete: @escaping () -> Void) {
        self.audio = audio; self.shareURL = shareURL; self.onPlay = onPlay; self.onStop = onStop
        self.onRename = onRename; self.onFavorite = onFavorite; self.onDelete = onDelete
        _name = State(initialValue: audio.displayName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Audio Name", text: $name)
                    LabeledContent("Created", value: audio.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Duration", value: SavedVoiceLibrary.formattedDuration(audio.duration))
                    LabeledContent("Language", value: audio.language ?? "--")
                    LabeledContent("Voice", value: sourceName)
                    if let text = audio.text { Text(text).font(.footnote) }
                }
                Section {
                    HStack {
                        Button("Play") { onPlay() }
                        Button("Stop") { onStop() }
                        if let shareURL { ShareLink(item: shareURL) { Label("Share", systemImage: "square.and.arrow.up") } }
                    }
                    Toggle("Favorite", isOn: Binding(get: { audio.isFavorite }, set: onFavorite))
                }
                Section {
                    Button("Save Changes") { onRename(name); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Delete Audio…", role: .destructive) { onDelete() }
                }
            }
            .navigationTitle("Generated Audio")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var sourceName: String {
        switch audio.sourceVoice {
        case .savedVoice: "Saved Voice"
        case .systemVoice: "System Voice"
        case .tinyLocalVoice: "Tiny Local Voice"
        case nil: "Unknown Voice"
        }
    }
}

private struct ImportAudioButton: View {
    @ObservedObject var model: VoiceStudioModel
    var onChoose: () -> Void = {}
    var onImported: (URL) -> Void = { _ in }
    @State private var isImporterPresented = false

    var body: some View {
        Button("Create From File") { onChoose(); isImporterPresented = true }
            .disabled(model.isRecording || model.isRequestingPermission)
            .accessibilityIdentifier("importButton")
            .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        let previousReferenceID = model.currentReference?.asset.id
                        model.importAudio(from: url)
                        if model.currentReference?.asset.id != previousReferenceID { onImported(url) }
                    }
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
