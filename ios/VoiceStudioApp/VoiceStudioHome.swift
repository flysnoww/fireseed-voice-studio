import AVFoundation
import PhotosUI
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoiceStudioCore

private enum StudioCardRoute: Identifiable {
    case voices, system, voice(VoiceSelection), history, settings
    var id: String { String(describing: self) }
}

struct VoiceStudioHome: View {
    @StateObject private var model: VoiceStudioModel
    @State private var card: StudioCardRoute?
    @State private var voiceName = "My voice"
    @State private var generationText = ""
    @FocusState private var focusedInput: Bool
    @EnvironmentObject private var appearance: AppAppearancePreference
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    init(model: VoiceStudioModel) { _model = StateObject(wrappedValue: model) }
    var body: some View {
        NavigationStack {
            ZStack {
                StudioBackdrop(skin: appearance.skin, imageURL: appearance.backgroundImageURL)
                    .onTapGesture { focusedInput = false }
                ScrollView {
                    VStack(spacing: 18) {
                        voiceSourceCard
                        StudioCard(title: "Current Voice", symbol: "person.wave.2") {
                            Button { card = .voice(model.currentVoice) } label: {
                                HStack {
                                    Text(model.voiceName(for: model.currentVoice)).font(.title3)
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }.accessibilityIdentifier("currentVoiceCard")
                            Button("Shape Voice") { card = .voice(model.currentVoice) }
                                .accessibilityIdentifier("shapeVoiceButton")
                        }
                        StudioCard(title: "Text", symbol: "text.alignleft") {
                            TextField("Enter text for your voice", text: $generationText, axis: .vertical)
                                .lineLimit(3...8).textFieldStyle(.roundedBorder).focused($focusedInput)
                                .accessibilityIdentifier("generationTextField")
                        }
                        StudioCard(title: "Generate", symbol: "waveform") {
                            HStack {
                                Button("Preview") { generate(preview: true) }
                                    .accessibilityIdentifier("previewSpeechButton")
                                Button(model.isGeneratingSpeech ? "Generating…" : "Generate") { generate(preview: false) }
                                    .accessibilityIdentifier("generateSpeechButton")
                            }.disabled(model.isGeneratingSpeech || !model.canGenerateCurrentVoice || generationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if model.isGeneratingSpeech || model.isResolvingVoice { ProgressView("Preparing…") }
                            if let audio = model.generatedAudio {
                                HStack {
                                    Button("Play") { model.playGeneratedAudio() }
                                    Button("Stop") { model.stopPlayback() }
                                    Button("Save Audio") { model.saveGeneratedAudio() }
                                        .disabled(audio.persistenceState == .persistent)
                                        .accessibilityIdentifier("saveGeneratedAudioButton")
                                    assetShare(audio)
                                }
                            }
                            Text(LocalizedStringKey(model.statusMessage)).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("statusMessage")
                        }
                        StudioCard(title: "Generation History", symbol: "square.stack") {
                            Button("Generation History") { card = .history }.accessibilityIdentifier("generatedAudioLibraryButton")
                        }
#if DEBUG || VOICE_STUDIO_DEVELOPER_DIAGNOSTICS
                        diagnosticsCard
#endif
                    }.padding(18).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Voice Studio").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { focusedInput = false; card = .settings } label: { Image(systemName: "person.circle") }
                        .accessibilityLabel("Settings").accessibilityIdentifier("settingsButton")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedInput = false } }
            }
            .tint(appearance.skin.accent)
            .sheet(item: $card) { route in
                switch route {
                case .voices: StudioVoiceLibrary(model: model, onSelected: { card = nil })
                case .system: StudioSystemVoicePicker(model: model, onSelected: { card = nil })
                case .voice(let voice): StudioVoiceDetail(model: model, selection: voice)
                case .history: StudioAudioLibrary(model: model)
                case .settings: StudioFloatingCard(title: "Settings") { SettingsView(model: model) }
                }
            }
            .task {
                await model.refreshTinyLocalModelState()
                await model.refreshOpenVoicePackState()
                await model.restoreCurrentVoiceAvailability()
            }
            .onChange(of: model.currentReference?.asset.id) { _, id in
                if id != nil { voiceName = String(localized: "My voice", locale: locale) }
            }
        }
    }
    private var voiceSourceCard: some View {
        StudioCard(title: "Voice", symbol: "person.2") {
            HStack(spacing: 8) {
                Button { focusedInput = false; card = .voices } label: { Label("My Voices", systemImage: "person.2") }
                    .frame(maxWidth: .infinity).accessibilityIdentifier("myVoicesButton")
                Button { focusedInput = false; card = .system } label: { Label("System Voices", systemImage: "waveform") }
                    .frame(maxWidth: .infinity).accessibilityIdentifier("systemVoicesButton")
                ImportAudioButton(model: model, onChoose: { focusedInput = false }, onImported: { url in
                    voiceName = url.deletingPathExtension().lastPathComponent
                }).frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).font(.subheadline)
            Button {
                focusedInput = false
                if model.isRecording { model.stopRecording() } else { Task { await model.startRecording() } }
            } label: { Label(model.isRecording ? "Stop Recording" : "Record Voice", systemImage: model.isRecording ? "stop.circle" : "mic") }
                .disabled(model.isRequestingPermission && !model.isRecording).accessibilityIdentifier("recordNewVoiceButton")
            if model.isRecording { Label("Recording in progress", systemImage: "record.circle.fill").foregroundStyle(.red) }
            if model.microphonePermissionDenied {
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
            }
            if model.currentReference != nil {
                Divider()
                Text("New Voice").font(.headline).accessibilityIdentifier("currentReferenceState")
                TextField("Voice Name", text: $voiceName).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("voiceNameField")
                HStack {
                    Button("Play") { model.playCurrentAudio() }.accessibilityIdentifier("playReferenceButton")
                    Button("Save Voice") { model.saveVoice(name: voiceName); focusedInput = false }
                        .disabled(!model.canSaveVoice || voiceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveVoiceButton")
                }
            }
        }
    }
    private func generate(preview: Bool) {
        focusedInput = false
        Task {
            let previous = model.generatedAudio?.id
            await model.generateCurrentVoice(text: generationText, preview: preview)
            if preview, model.generatedAudio?.id != previous { model.playGeneratedAudio() }
        }
    }
    @ViewBuilder private func assetShare(_ audio: AudioAsset) -> some View {
        if let url = model.shareURL(for: audio) { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") } }
        else { Button("Share") { model.statusMessage = "This audio could not be shared. Please try again." } }
    }
    private var diagnosticsCard: some View {
        StudioCard(title: "Developer Diagnostics", symbol: "stethoscope") {
            let snapshot = model.diagnostics.snapshot
            LabeledContent("Current Voice", value: model.voiceName(for: model.currentVoice))
            LabeledContent("Voice Source", value: snapshot.voiceSource)
            LabeledContent("System Voice ID", value: snapshot.systemVoiceIdentifier ?? "—")
            LabeledContent("Quality", value: snapshot.systemVoiceQuality.map(String.init) ?? "—")
            LabeledContent("Language", value: model.currentVoiceProfile.language)
            LabeledContent("Accent", value: model.currentVoiceProfile.accent ?? "—")
            LabeledContent("Route", value: snapshot.provider)
            LabeledContent("Load ms", value: snapshot.openVoiceLoadMilliseconds.map(String.init) ?? "—")
            LabeledContent("Embedding ms", value: snapshot.embeddingPrepareMilliseconds.map(String.init) ?? "—")
            LabeledContent("Conversion ms", value: snapshot.conversionMilliseconds.map(String.init) ?? "—")
            LabeledContent("RTF", value: snapshot.realTimeFactor.map { String(format: "%.2f", $0) } ?? "—")
            LabeledContent("Footprint MB", value: snapshot.physicalFootprintMB.map(String.init) ?? "—")
            ForEach(model.diagnostics.stages, id: \.stage) { result in
                LabeledContent(result.stage.rawValue, value: result.durationMilliseconds.map { "\($0) ms" } ?? result.state.rawValue)
            }
        }.font(.caption)
    }
}

struct StudioFloatingCard<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top) { if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) } }
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("floatingCardClose")
                } }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationCornerRadius(28).presentationBackground(.regularMaterial)
        .presentationContentInteraction(.scrolls)
    }
}

private struct VoiceDetailSelection: Identifiable {
    let voice: VoiceSelection
    var id: String { String(describing: voice) }
}

struct StudioVoiceLibrary: View {
    @ObservedObject var model: VoiceStudioModel
    let onSelected: () -> Void
    @State private var detail: VoiceDetailSelection?
    var body: some View {
        StudioFloatingCard(title: "My Voices") {
            List {
                Picker("Sort", selection: Binding(get: { model.savedVoiceFilter }, set: { model.setSavedVoiceFilter($0) })) {
                    Text("Time").tag(SavedVoiceFilter.time)
                    Text("Imported").tag(SavedVoiceFilter.imported)
                    Text("Recorded").tag(SavedVoiceFilter.recorded)
                }.pickerStyle(.segmented)
                if model.savedVoices.isEmpty { Text("No saved voices yet.").foregroundStyle(.secondary) }
                ForEach(model.pagedSavedVoices) { voice in
                    HStack {
                        Button { model.selectVoice(.saved(voice.id)); onSelected() } label: {
                            Image(systemName: model.currentVoice == .saved(voice.id) ? "checkmark.circle.fill" : "circle")
                        }.accessibilityLabel("Select \(voice.name)").accessibilityIdentifier("savedVoiceChoice-\(voice.id.uuidString)")
                        Button { model.selectVoice(.saved(voice.id)); detail = VoiceDetailSelection(voice: .saved(voice.id)) } label: {
                            VStack(alignment: .leading) { Text(voice.name); Text(SavedVoiceLibrary.formattedDuration(voice.referenceAudio.duration)).font(.caption) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.accessibilityIdentifier("voiceDetail-\(voice.id.uuidString)")
                    }.buttonStyle(.plain).listRowBackground(model.currentVoice == .saved(voice.id) ? Color.accentColor.opacity(0.12) : Color.clear)
                }
                if model.savedVoicePageCount > 1 {
                    HStack {
                        Button("Previous") { model.setSavedVoicePage(model.savedVoicePage - 1) }.disabled(model.savedVoicePage == 0)
                        Spacer(); Text("\(model.savedVoicePage + 1) / \(model.savedVoicePageCount)"); Spacer()
                        Button("Next") { model.setSavedVoicePage(model.savedVoicePage + 1) }.disabled(model.savedVoicePage + 1 >= model.savedVoicePageCount)
                    }
                }
                if model.isTinyLocalModelReady {
                    Section("Local Voices") {
                        Button { model.selectVoice(.tinyLocal); detail = VoiceDetailSelection(voice: .tinyLocal) } label: {
                            Label("Local English Voice", systemImage: model.currentVoice == .tinyLocal ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }.accessibilityIdentifier("myVoicesFloatingCard")
                .sheet(item: $detail) { StudioVoiceDetail(model: model, selection: $0.voice) }
        }
    }
}

private struct LanguageChoice: Identifiable { let id: String }
struct StudioSystemVoicePicker: View {
    @ObservedObject var model: VoiceStudioModel
    let onSelected: () -> Void
    @State private var language: LanguageChoice?
    @Environment(\.locale) private var locale
    var body: some View {
        StudioFloatingCard(title: "System Voices") {
            List {
                if model.personalVoiceAuthorization == .notDetermined {
                    Button("Allow Apple Personal Voice") { Task { await model.authorizePersonalVoice() } }
                        .accessibilityIdentifier("personalVoiceAuthorizationButton")
                }
                ForEach(languages, id: \.self) { code in
                    Button { language = LanguageChoice(id: code) } label: {
                        HStack { Text(locale.localizedString(forLanguageCode: code) ?? code); Spacer(); Image(systemName: "chevron.right") }
                    }.accessibilityIdentifier("systemLanguage-\(code)")
                }
            }.accessibilityIdentifier("systemLanguageFloatingCard")
                .sheet(item: $language) { choice in
                    StudioSystemLanguageVoices(model: model, language: choice.id, onSelected: onSelected)
                }
        }
    }
    var languages: [String] {
        let candidates = model.systemVoiceCandidates.filter { model.systemVoiceAvailability.results[$0.identifier] != .failed }
        return SystemVoiceCatalog.rankLanguages(Array(SystemVoiceCatalog.groupByBaseLanguage(candidates).keys), systemLanguage: Locale.preferredLanguages.first ?? "en", locale: locale)
    }
}

struct StudioSystemLanguageVoices: View {
    @ObservedObject var model: VoiceStudioModel
    let language: String
    let onSelected: () -> Void
    @State private var showAll = false
    @State private var isProbing = true
    @Environment(\.locale) private var locale
    var body: some View {
        StudioFloatingCard(title: LocalizedStringKey(locale.localizedString(forLanguageCode: language) ?? language)) {
            List {
                if isProbing { ProgressView("Checking voices…") }
                if !isProbing && voices.isEmpty { Text("No usable voices are available for this language.") }
                ForEach(showAll ? voices : Array(voices.prefix(8))) { voice in
                    Button { model.selectVoice(.systemVoice(voice.identifier)); onSelected() } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(voice.name)
                                Text(locale.localizedString(forIdentifier: voice.language) ?? voice.language).font(.caption).foregroundStyle(.secondary)
                                if voice.isPersonal { Text("Personal Voice").font(.caption) }
                                if voice.gender != 0 { Text(voice.gender == 1 ? "Male" : "Female").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: model.currentVoice == .systemVoice(voice.identifier) ? "checkmark.circle.fill" : "circle")
                        }
                    }.accessibilityIdentifier("systemVoice-\(voice.identifier)")
                }
                if !showAll && model.systemVoiceCandidates.filter({ SystemVoiceCatalog.baseLanguage($0.language) == language }).count > 8 {
                    Button("More Voices") { showAll = true }
                }
            }.accessibilityIdentifier("systemVoicesFloatingCard")
                .task(id: showAll) { isProbing = true; await model.probeSystemLanguage(language, all: showAll); isProbing = false }
        }
    }
    var voices: [SystemVoiceDescriptor] {
        SystemVoiceCatalog.rankVoices(model.usableSystemVoices.filter { SystemVoiceCatalog.baseLanguage($0.language) == language }, locale: locale)
    }
}

struct StudioVoiceDetail: View {
    @ObservedObject var model: VoiceStudioModel
    let selection: VoiceSelection
    @State private var name = ""
    @State private var option: LanguageChoice?
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private var voice: VoiceAsset? { selection.savedVoiceID.flatMap { id in model.savedVoices.first { $0.id == id } } }
    private var profile: VoiceProfile { model.profile(for: selection) }
    var body: some View {
        StudioFloatingCard(title: "Shape Voice") {
            Form {
                Section {
                    Text(model.voiceName(for: selection)).font(.title2)
                    Text(selection.savedVoiceID != nil ? "My Voice" : (selection == .tinyLocal ? "Local Voice" : "System Voice")).foregroundStyle(.secondary)
                    Button {
                        model.selectVoice(selection)
                    } label: { Label(model.currentVoice == selection ? "Current Voice" : "Select Voice", systemImage: model.currentVoice == selection ? "checkmark.circle.fill" : "circle") }
                        .accessibilityIdentifier("voiceCurrentIndicator")
                    if let voice {
                        HStack {
                            Button("Play") { model.playVoiceReference(voice) }
                            if let url = model.shareURL(for: voice.referenceAudio) { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") } }
                            else { Button("Share") { model.statusMessage = "This voice could not be shared. Please try again." } }
                        }
                        Toggle("Favorite", isOn: Binding(get: { self.voice?.isFavorite ?? false }, set: { model.setSavedVoiceFavorite(id: voice.id, isFavorite: $0) }))
                    }
                }
                Section("Voice Shaping") {
                    LabeledContent("Speed", value: String(format: "%.2f×", profile.speed))
                    Slider(value: profileBinding(\.speed), in: 0.5...2, step: 0.05).accessibilityLabel("Speed").accessibilityIdentifier("voiceSpeedSlider")
                    LabeledContent("Pitch", value: String(format: "%.0f", profile.pitch))
                    Slider(value: profileBinding(\.pitch), in: -1200...1200, step: 50).accessibilityLabel("Pitch").accessibilityIdentifier("voicePitchSlider")
                }
                Section {
                    if languages.count > 1 {
                        Button { option = LanguageChoice(id: "language") } label: { LabeledContent("Language", value: displayLanguage(profile.language) + " ›") }
                            .accessibilityIdentifier("voiceLanguageButton")
                    } else { LabeledContent("Language", value: displayLanguage(profile.language)) }
                    if accents.count > 1 {
                        Button { option = LanguageChoice(id: "accent") } label: { LabeledContent("Accent", value: displayAccent(profile.accent) + " ›") }
                            .accessibilityIdentifier("voiceAccentButton")
                    } else if let accent = profile.accent { LabeledContent("Accent", value: displayAccent(accent)) }
                }
                if let voice {
                    Section {
                        TextField("Voice Name", text: $name).accessibilityIdentifier("renameVoiceField")
                        Button("Rename") { model.renameSavedVoice(id: voice.id, name: name) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.isLocalSpeechReady || model.isAdvancedPackInstalled {
                            Picker("Rendering Preference", selection: profileBinding(\.renderingPreference)) {
                                Text("Standard").tag(VoiceRenderingPreference.automatic)
                                Text("Advanced Local Voice").tag(VoiceRenderingPreference.advancedLocal)
                            }
                        }
                        Button("Delete Voice…", role: .destructive) { deleting = true }
                    }
                } else {
                    Section {
                        TextField("Preview Text", text: $name)
                        Button("Preview") { model.selectVoice(selection); Task { let previous = model.generatedAudio?.id; await model.generateCurrentVoice(text: name, preview: true); if model.generatedAudio?.id != previous { model.playGeneratedAudio() } } }
                            .disabled(model.isGeneratingSpeech || name.isEmpty)
                        if let audio = model.generatedAudio, audio.sourceVoice == source {
                            if let url = model.shareURL(for: audio) { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") } }
                        }
                    }
                }
            }.accessibilityIdentifier("voiceDetailFloatingCard")
                .onAppear { name = voice?.name ?? String(localized: "Hello.", locale: locale) }
                .task { if selection.savedVoiceID != nil { await model.probeSystemLanguage(profile.language) } }
                .confirmationDialog("Delete Voice?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { if let voice { model.deleteSavedVoice(id: voice.id) }; dismiss() }
                }
                .sheet(item: $option) { choice in
                    StudioFloatingCard(title: choice.id == "language" ? "Language" : "Accent") {
                        List {
                            ForEach(choice.id == "language" ? languages : accents, id: \.self) { value in
                                Button {
                                    var updated = profile
                                    if choice.id == "language" { updated.language = value; updated.accent = nil }
                                    else { updated.accent = value }
                                    model.updateProfile(updated, for: selection); option = nil
                                    Task { await model.probeSystemLanguage(updated.language) }
                                } label: {
                                    HStack { Text(choice.id == "language" ? displayLanguage(value) : displayAccent(value)); Spacer()
                                        if value == (choice.id == "language" ? profile.language : profile.accent) { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }.accessibilityIdentifier(choice.id == "language" ? "voiceLanguageFloatingCard" : "voiceAccentFloatingCard")
                    }
                }
        }
    }
    private func profileBinding<T>(_ key: WritableKeyPath<VoiceProfile, T>) -> Binding<T> {
        Binding(get: { profile[keyPath: key] }, set: { value in var updated = profile; updated[keyPath: key] = value; model.updateProfile(updated, for: selection) })
    }
    private var source: GeneratedAudioVoiceSource {
        switch selection { case .tinyLocal: .tinyLocalVoice("tiny-local"); case .systemVoice(let id): .systemVoice(id); default: .systemVoice(nil) }
    }
    private var languages: [String] {
        if selection.savedVoiceID != nil { return model.availableLanguages(for: selection) }
        return [profile.language]
    }
    private var accents: [String] {
        if case .systemVoice = selection { return profile.accent.map { [$0] } ?? [] }
        return Array(Set(model.usableSystemVoices.filter { SystemVoiceCatalog.baseLanguage($0.language) == profile.language }.map(\.language))).sorted()
    }
    private func displayLanguage(_ language: String) -> String { locale.localizedString(forLanguageCode: language) ?? language }
    private func displayAccent(_ accent: String?) -> String { accent.map { locale.localizedString(forIdentifier: $0) ?? $0 } ?? "—" }
}

struct StudioAudioLibrary: View {
    @ObservedObject var model: VoiceStudioModel
    @State private var selected: AudioAsset?
    var body: some View {
        StudioFloatingCard(title: "Generation History") {
            List {
                ForEach(model.pagedGeneratedAudio) { audio in
                    Button { selected = audio } label: { VStack(alignment: .leading) { Text(audio.displayName); Text(SavedVoiceLibrary.formattedDuration(audio.duration)).font(.caption) } }
                        .accessibilityIdentifier("generatedAudio-\(audio.id.uuidString)")
                }
                if model.savedGeneratedAudio.isEmpty { Text("No saved audio yet.") }
                if model.generatedAudioPageCount > 1 {
                    HStack {
                        Button("Previous") { model.setGeneratedAudioPage(model.generatedAudioPage - 1) }.disabled(model.generatedAudioPage == 0)
                        Spacer(); Text("\(model.generatedAudioPage + 1) / \(model.generatedAudioPageCount)"); Spacer()
                        Button("Next") { model.setGeneratedAudioPage(model.generatedAudioPage + 1) }.disabled(model.generatedAudioPage + 1 >= model.generatedAudioPageCount)
                    }
                }
            }.sheet(item: $selected) { audio in
                GeneratedAudioEditor(audio: audio, shareURL: model.shareURL(for: audio), onPlay: { model.playAudioAsset(audio) }, onStop: model.stopPlayback,
                                     onRename: { model.renameGeneratedAudio(id: audio.id, name: $0) }, onFavorite: { model.setGeneratedAudioFavorite(id: audio.id, isFavorite: $0) },
                                     onDelete: { model.deleteGeneratedAudio(id: audio.id); selected = nil })
            }
        }
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
    @State private var isAccountPresented = false
    @State private var settingsChild: LanguageChoice?
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
                    Button { isAccountPresented = true } label: {
                        Label("Account", systemImage: "person.circle")
                        Text("Not signed in").foregroundStyle(.secondary)
                    }.accessibilityIdentifier("accountPlaceholderLink")
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
                Section("Language") {
                    Button { settingsChild = LanguageChoice(id: "language") } label: {
                        HStack { Text("App Language"); Spacer(); Text(languagePreference.language.displayName); Image(systemName: "chevron.right") }
                    }.accessibilityIdentifier("appLanguagePicker")
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
                Section("Appearance") {
                    Button { settingsChild = LanguageChoice(id: "skin") } label: {
                        HStack { Text("App Skin"); Spacer(); Text(appearance.skin.displayName); Image(systemName: "chevron.right") }
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
                        Button(model.isDownloadingTinyLocalVoice ? "Loading…" : "Download Local English Voice") { Task { await model.installTinyLocalVoice() } }
                            .disabled(model.isDownloadingTinyLocalVoice)
                    }
                    Button(model.isDeletingTinyLocalModel ? "Removing…" : "Remove Local Voice Data", role: .destructive) {
                        Task { await model.deleteTinyLocalModel() }
                    }
                    .disabled(!model.isTinyLocalModelReady || model.isDeletingTinyLocalModel || model.isGeneratingSpeech)
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
                DisclosureGroup("Advanced Optional Voice") {
                    Button(model.isInstallingLocalSpeech ? "Loading…" :
                           (model.isLocalSpeechReady ? "Local speech is ready." : "Import Advanced Voice Pack")) {
                        isSpeechComponentImporterPresented = true
                    }
                    .disabled(model.isInstallingLocalSpeech || model.isGeneratingSpeech)
                    .accessibilityIdentifier("speechComponentImportButton")
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
                Section("Optional Voice Pack") {
                    Label(model.isOpenVoicePackReady ? "Optional pack validated" : "Optional pack not installed",
                          systemImage: model.isOpenVoicePackReady ? "checkmark.circle" : "arrow.down.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(model.isInstallingOpenVoicePack ? "Validating…" : "Install or Replace Voice Pack") {
                        isOpenVoicePackImporterPresented = true
                    }.disabled(model.isInstallingOpenVoicePack || model.isGeneratingSpeech || model.isPreparingOpenVoiceTarget)
                    Button("Validate Voice Pack") { Task { await model.refreshOpenVoicePackState() } }
                        .disabled(model.isInstallingOpenVoicePack || model.isPreparingOpenVoiceTarget)
                    Button(model.isDeletingOpenVoicePack ? "Removing…" : "Remove Voice Pack", role: .destructive) {
                        Task { await model.deleteOpenVoicePack() }
                    }.disabled(!model.isOpenVoicePackReady || model.isDeletingOpenVoicePack || model.isGeneratingSpeech || model.isPreparingOpenVoiceTarget)
                    Text("Use your saved voices to generate speech with the optional voice pack.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Keep the original voice reference for future voice pack updates.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
        }
        .tint(appearance.skin.accent)
        .sheet(isPresented: $isAccountPresented) { StudioFloatingCard(title: "Account") { AccountPlaceholderView() } }
        .sheet(item: $settingsChild) { child in
            StudioFloatingCard(title: child.id == "language" ? "App Language" : "App Skin") {
                List {
                    if child.id == "language" {
                        ForEach(AppLanguage.allCases) { language in
                            Button { languagePreference.set(language); settingsChild = nil } label: {
                                HStack { Text(language.displayName); Spacer(); if languagePreference.language == language { Image(systemName: "checkmark") } }
                            }
                        }
                    } else {
                        ForEach(AppSkin.allCases) { skin in
                            Button { appearance.setSkin(skin); settingsChild = nil } label: {
                                HStack { Text(skin.displayName); Spacer(); if appearance.skin == skin { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                }
            }
        }
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
                model.statusMessage = "Voice pack could not be imported."
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
    @State private var favorite: Bool
    @State private var deleting = false

    init(audio: AudioAsset, shareURL: URL?, onPlay: @escaping () -> Void, onStop: @escaping () -> Void,
         onRename: @escaping (String) -> Void, onFavorite: @escaping (Bool) -> Void,
         onDelete: @escaping () -> Void) {
        self.audio = audio; self.shareURL = shareURL; self.onPlay = onPlay; self.onStop = onStop
        self.onRename = onRename; self.onFavorite = onFavorite; self.onDelete = onDelete
        _name = State(initialValue: audio.displayName)
        _favorite = State(initialValue: audio.isFavorite)
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
                    Toggle("Favorite", isOn: Binding(get: { favorite }, set: { favorite = $0; onFavorite($0) }))
                }
                Section {
                    Button("Save Changes") { onRename(name); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Delete Audio…", role: .destructive) { deleting = true }
                }
            }
            .navigationTitle("Generated Audio")
            .accessibilityIdentifier("generatedAudioFloatingCard")
            .confirmationDialog("Delete Audio?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { onDelete(); dismiss() }
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationCornerRadius(28).presentationBackground(.regularMaterial)
        .presentationContentInteraction(.scrolls).accessibilityIdentifier("generatedAudioFloatingCard")
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
        Button("Import Voice") { onChoose(); isImporterPresented = true }
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
