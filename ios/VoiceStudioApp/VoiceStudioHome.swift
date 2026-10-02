import AVFoundation
import PhotosUI
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VoiceStudioCore

enum StudioCardRoute: Equatable {
    case voices, system, systemLanguage(String), voice(VoiceSelection), voiceOption(VoiceSelection, Bool)
    case history(Bool), audio(UUID), imitation, settings, account, appLanguage, skin
}
struct StudioCardEntry: Identifiable { let id = UUID(); let route: StudioCardRoute }
@MainActor final class FloatingCardStack: ObservableObject {
    @Published private(set) var entries: [StudioCardEntry] = []
    func push(_ route: StudioCardRoute) {
        guard entries.count < 8, entries.last?.route != route else { return }
        entries.append(StudioCardEntry(route: route))
    }
    func pop() { if !entries.isEmpty { entries.removeLast() } }
    func dismissAll() { entries.removeAll() }
    func reconcile(voices: Set<UUID>, audio: Set<UUID>) {
        if let invalid = entries.firstIndex(where: { entry in
            switch entry.route {
            case .voice(let voice), .voiceOption(let voice, _): return voice.savedVoiceID.map { !voices.contains($0) } ?? false
            case .audio(let id): return !audio.contains(id)
            default: return false
            }
        }) { entries.removeSubrange(invalid...) }
    }
}

struct VoiceStudioHome: View {
    @StateObject private var model: VoiceStudioModel
    @StateObject private var cards = FloatingCardStack()
    @EnvironmentObject private var languagePreference: AppLanguagePreference
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        StudioCard(title: "Current Voice", symbol: "person.wave.2") {
                            Button { cards.push(.voice(model.currentVoice)) } label: {
                                HStack {
                                    Image(systemName: "person.wave.2.fill").font(.system(size: 34)).padding(8)
                                    Text(model.voiceName(for: model.currentVoice, locale: locale)).font(.title2.bold())
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }.accessibilityIdentifier("currentVoiceCard")
                            HStack {
                                StudioIcon("Play", symbol: "play.fill") { model.audition(model.currentVoice, locale: locale) }
                                StudioIcon("Stop", symbol: "stop.fill") { model.stopPlayback() }
                                Spacer()
                                Button { cards.push(.voice(model.currentVoice)) } label: { Label("Shape Voice", systemImage: "slider.horizontal.3") }.accessibilityIdentifier("shapeVoiceButton")
                            }
                        }
                        voiceSourceCard
                        StudioCard(title: "Text", symbol: "text.alignleft") {
                            TextField("Enter text for your voice", text: $generationText, axis: .vertical)
                                .lineLimit(3...8).textFieldStyle(.roundedBorder).focused($focusedInput)
                                .accessibilityIdentifier("generationTextField")
                        }
                        StudioCard(title: "Generate", symbol: "waveform") {
                            HStack {
                                Button("Preview") { generate(preview: true) }
                                    .accessibilityIdentifier("previewSpeechButton")
                                Button { generate(preview: false) } label: { Label(model.isGeneratingSpeech ? "Generating…" : "Generate", systemImage: "waveform").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("generateSpeechButton")
                            }.disabled(model.isGeneratingSpeech || !model.canGenerateCurrentVoice || generationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if model.isGeneratingSpeech || model.isResolvingVoice { HStack { ProgressView("Preparing…"); Spacer(); StudioIcon("Cancel", symbol: "xmark") { model.cancelGeneration() } } }
                            if let audio = model.generatedAudio {
                                HStack {
                                    StudioIcon("Play", symbol: "play.fill") { model.playGeneratedAudio() }
                                    StudioIcon("Stop", symbol: "stop.fill") { model.stopPlayback() }
                                    Button("Save Audio") { model.saveGeneratedAudio() }
                                        .disabled(audio.persistenceState == .persistent)
                                        .accessibilityIdentifier("saveGeneratedAudioButton")
                                    assetShare(audio)
                                }
                            }
                            Text(LocalizedStringKey(model.statusMessage)).font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("statusMessage")
                        }
                        HStack {
                            Button { cards.push(.imitation) } label: { Label("Imitate", systemImage: "person.wave.2") }.accessibilityIdentifier("imitateButton")
                            Spacer()
                            Button("Generation History") { cards.push(.history(false)) }.accessibilityIdentifier("generatedAudioLibraryButton")
                        }
#if DEBUG || VOICE_STUDIO_DEVELOPER_DIAGNOSTICS
                        DisclosureGroup("Developer Diagnostics") { diagnosticsCard }
#endif
                    }.padding(18).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }.scrollDismissesKeyboard(.interactively)
                    .blur(radius: cards.entries.isEmpty ? 0 : 2)
                    .allowsHitTesting(cards.entries.isEmpty).accessibilityHidden(!cards.entries.isEmpty)
                if !cards.entries.isEmpty {
                    Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { cards.dismissAll() }
                    GeometryReader { geometry in
                        ZStack {
                            ForEach(Array(cards.entries.enumerated()), id: \.element.id) { index, entry in
                                let depth = cards.entries.count - index - 1
                                StudioCardLayer(depth: depth, height: geometry.size.height - 60) {
                                    cardContent(entry.route)
                                }.zIndex(Double(index))
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 18)
                    }
                }
            }
            .navigationTitle("Voice Studio").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { focusedInput = false; cards.push(.settings) } label: { Image(systemName: "person.circle") }
                        .accessibilityLabel("Settings").accessibilityIdentifier("settingsButton")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedInput = false; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
            }
            .tint(appearance.skin.accent)
            .environmentObject(cards)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .interactiveSpring(response: 0.36, dampingFraction: 0.88), value: cards.entries.map(\.id))
            .onChange(of: cards.entries.count) { _, depth in focusedInput = false; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); model.diagnostics.update { $0.routeDepth = depth } }
            .onChange(of: model.savedVoices.map(\.id)) { _, _ in reconcile() }
            .onChange(of: model.savedGeneratedAudio.map(\.id)) { _, _ in reconcile() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { model.applicationDidEnterBackground() } }
            .task {
                await model.refreshTinyLocalModelState()
                await model.refreshOpenVoicePackState()
                await model.restoreCurrentVoiceAvailability()
            }
            .onChange(of: model.currentReference?.asset.id) { _, id in
                if id != nil, model.currentReference?.source == .record { voiceName = String(localized: "My voice", locale: locale) }
            }
        }
    }
    private var voiceSourceCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Button { focusedInput = false; cards.push(.voices) } label: { VStack { Image(systemName: "person.2").font(.title3); Text("My Voices").font(.caption) }.frame(maxWidth: .infinity, minHeight: 58) }
                    .frame(maxWidth: .infinity).accessibilityIdentifier("myVoicesButton")
                Button { focusedInput = false; cards.push(.system) } label: { VStack { Image(systemName: "waveform").font(.title3); Text("System Voices").font(.caption) }.frame(maxWidth: .infinity, minHeight: 58) }
                    .frame(maxWidth: .infinity).accessibilityIdentifier("systemVoicesButton")
                ImportAudioButton(model: model, onChoose: { focusedInput = false }, onImported: { url in
                    voiceName = url.deletingPathExtension().lastPathComponent
                }).frame(maxWidth: .infinity)
            Button {
                focusedInput = false
                if model.isRecording { model.stopRecording() } else { Task { await model.startRecording() } }
            } label: { VStack { Image(systemName: model.isRecording ? "stop.circle" : "mic.fill").font(.title3); Text(model.isRecording ? "Stop Recording" : "Record Voice").font(.caption) }.frame(maxWidth: .infinity, minHeight: 58) }
                .disabled(model.isRequestingPermission && !model.isRecording).accessibilityIdentifier("recordNewVoiceButton")
            }.buttonStyle(.bordered)
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
                    StudioIcon("Play", symbol: "play.fill") { model.playCurrentAudio() }.accessibilityIdentifier("playReferenceButton")
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
    private func assetShare(_ audio: AudioAsset) -> some View { StudioShare(model: model, audio: audio) }
    private func reconcile() { cards.reconcile(voices: Set(model.savedVoices.map(\.id)), audio: Set(model.savedGeneratedAudio.map(\.id))) }
    @ViewBuilder private func cardContent(_ route: StudioCardRoute) -> some View {
        switch route {
        case .voices: StudioVoiceLibrary(model: model, onSelected: cards.dismissAll)
        case .system: StudioSystemVoicePicker(model: model, onSelected: cards.dismissAll)
        case .systemLanguage(let language): StudioSystemLanguageVoices(model: model, language: language, onSelected: cards.dismissAll)
        case .voice(let voice): StudioVoiceDetail(model: model, selection: voice)
        case .voiceOption(let voice, let accent): StudioVoiceOptions(model: model, selection: voice, accent: accent)
        case .history(let choosing): StudioAudioLibrary(model: model, choosingPerformance: choosing)
        case .audio(let id): StudioAudioDetail(model: model, id: id)
        case .imitation: StudioImitation(model: model)
        case .settings: StudioFloatingCard(title: "Settings") { SettingsView(model: model) }
        case .account: StudioFloatingCard(title: "Account") { AccountPlaceholderView() }
        case .appLanguage: StudioFloatingCard(title: "App Language") {
            VStack { ForEach(AppLanguage.allCases) { language in
                Button { languagePreference.set(language); cards.pop() } label: { HStack { Text(language.displayName); Spacer(); if languagePreference.language == language { Image(systemName: "checkmark") } }.padding() }
            }; Spacer() }.padding()
        }
        case .skin: StudioFloatingCard(title: "App Skin") {
            VStack { ForEach(AppSkin.allCases) { skin in
                Button { appearance.setSkin(skin); cards.pop() } label: { HStack { Text(skin.displayName); Spacer(); if appearance.skin == skin { Image(systemName: "checkmark") } }.padding() }
            }; Spacer() }.padding()
        }
        }
    }
    private var diagnosticsCard: some View {
        StudioCard(title: "Developer Diagnostics", symbol: "stethoscope") {
            let snapshot = model.diagnostics.snapshot
            HStack {
                Button("Copy Diagnostics") { UIPasteboard.general.string = model.diagnostics.exportText() }
                ShareLink(item: model.diagnostics.exportText()) { Label("Share Diagnostics", systemImage: "square.and.arrow.up") }
            }
            LabeledContent("Current Voice", value: model.voiceName(for: model.currentVoice, locale: locale))
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

private struct StudioCardLayer<Content: View>: View {
    let depth: Int
    let height: CGFloat
    @ViewBuilder var content: Content
    @EnvironmentObject private var appearance: AppAppearancePreference
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        content.frame(maxWidth: 620, maxHeight: max(CGFloat(200), height))
            .background(appearance.skin.material, in: RoundedRectangle(cornerRadius: 30))
            .overlay(RoundedRectangle(cornerRadius: 30).stroke(Color.white.opacity(0.4)))
            .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
            .scaleEffect(reduceMotion ? 1 : max(0.86, 1 - CGFloat(depth) * 0.045), anchor: .top)
            .offset(y: reduceMotion ? 0 : -CGFloat(min(depth, 3)) * 14)
            .opacity(depth == 0 ? 1 : 0.82)
            .allowsHitTesting(depth == 0).accessibilityHidden(depth != 0)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
    }
}
struct StudioIcon: View {
    let title: LocalizedStringKey; let symbol: String; let action: () -> Void
    init(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) { self.title = title; self.symbol = symbol; self.action = action }
    var body: some View { Button(action: action) { Image(systemName: symbol).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(title) }
}
struct StudioFloatingCard<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    @EnvironmentObject private var cards: FloatingCardStack
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                StudioIcon("Back", symbol: "chevron.left") { cards.pop() }.accessibilityIdentifier("floatingCardBack")
                Spacer(); Text(title).font(.headline); Spacer()
                StudioIcon("Close", symbol: "xmark") { cards.dismissAll() }.accessibilityIdentifier("floatingCardClose")
            }.padding(.horizontal, 10).padding(.top, 6)
            if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.clipShape(RoundedRectangle(cornerRadius: 30))
    }
}
private struct LanguageChoice: Identifiable { let id: String }
struct StudioVoiceLibrary: View {
    @ObservedObject var model: VoiceStudioModel
    let onSelected: () -> Void
    @EnvironmentObject private var cards: FloatingCardStack
    var body: some View {
        StudioFloatingCard(title: "My Voices") {
            ScrollView { VStack(alignment: .leading, spacing: 16) {
                Picker("Sort", selection: Binding(get: { model.savedVoiceFilter }, set: { model.setSavedVoiceFilter($0) })) {
                    Text("Time").tag(SavedVoiceFilter.time)
                    Text("Imported").tag(SavedVoiceFilter.imported)
                    Text("Recorded").tag(SavedVoiceFilter.recorded)
                }.pickerStyle(.segmented)
                if model.savedVoices.isEmpty { Text("No saved voices yet.").foregroundStyle(.secondary) }
                ForEach(model.pagedSavedVoices) { voice in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { cards.push(.voice(.saved(voice.id))) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(voice.name).font(.headline)
                                    Text(voice.sourceType == .record ? "Recorded" : "Imported").font(.caption)
                                    Text("\(voice.profile.accent ?? voice.profile.language) · \(SavedVoiceLibrary.formattedDuration(voice.referenceAudio.duration))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.currentVoice == .saved(voice.id) { Image(systemName: "checkmark.circle.fill") }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("voiceDetail-\(voice.id.uuidString)")
                        HStack {
                            StudioIcon("Play", symbol: "play.fill") { model.playVoiceReference(voice) }
                            StudioIcon("Shape Voice", symbol: "slider.horizontal.3") { cards.push(.voice(.saved(voice.id))) }
                            StudioShare(model: model, audio: voice.referenceAudio)
                            Spacer()
                            StudioIcon("Favorite", symbol: voice.isFavorite ? "star.fill" : "star") { model.setSavedVoiceFavorite(id: voice.id, isFavorite: !voice.isFavorite) }
                        }
                    }.padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(model.currentVoice == .saved(voice.id) ? Color.accentColor : .clear, lineWidth: 2))
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
                        Button { cards.push(.voice(.tinyLocal)) } label: {
                            Label("Local English Voice", systemImage: model.currentVoice == .tinyLocal ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }.padding(20) }.accessibilityIdentifier("myVoicesFloatingCard")

        }
    }
}

struct StudioSystemVoicePicker: View {
    @ObservedObject var model: VoiceStudioModel
    let onSelected: () -> Void
    @EnvironmentObject private var cards: FloatingCardStack
    @Environment(\.locale) private var locale
    var body: some View {
        StudioFloatingCard(title: "System Voices") {
            ScrollView { VStack(alignment: .leading, spacing: 16) {
                if model.personalVoiceAuthorization == .notDetermined {
                    Button("Allow Apple Personal Voice") { Task { await model.authorizePersonalVoice() } }
                        .accessibilityIdentifier("personalVoiceAuthorizationButton")
                }
                ForEach(languages, id: \.self) { code in
                    Button { cards.push(.systemLanguage(code)) } label: {
                        HStack { Text(locale.localizedString(forLanguageCode: code) ?? code); Spacer(); Image(systemName: "chevron.right") }
                    }.padding(18).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20)).accessibilityIdentifier("systemLanguage-\(code)")
                }
            }.padding(20) }.accessibilityIdentifier("systemLanguageFloatingCard")

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
            ScrollView { VStack(alignment: .leading, spacing: 16) {
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
                    }.padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20)).accessibilityIdentifier("systemVoice-\(voice.identifier)")
                    StudioIcon("Play", symbol: "play.fill") { model.audition(.systemVoice(voice.identifier), locale: locale) }
                }
                if !showAll && model.systemVoiceCandidates.filter({ SystemVoiceCatalog.baseLanguage($0.language) == language }).count > 8 {
                    Button("More Voices") { showAll = true }
                }
            }.padding(20) }.accessibilityIdentifier("systemVoicesFloatingCard")
                .task(id: showAll) { isProbing = true; await model.probeSystemLanguage(language, all: showAll); if !Task.isCancelled { isProbing = false } }
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
    @EnvironmentObject private var cards: FloatingCardStack
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    private var voice: VoiceAsset? { selection.savedVoiceID.flatMap { id in model.savedVoices.first { $0.id == id } } }
    private var profile: VoiceProfile { model.profile(for: selection) }
    var body: some View {
        StudioFloatingCard(title: "Shape Voice") {
            ScrollView { VStack(alignment: .leading, spacing: 22) {
                Section {
                    Text(model.voiceName(for: selection, locale: locale)).font(.title2)
                    Text(selection.savedVoiceID != nil ? "My Voice" : (selection == .tinyLocal ? "Local Voice" : "System Voice")).foregroundStyle(.secondary)
                    Button {
                        model.selectVoice(selection)
                    } label: { Label(model.currentVoice == selection ? "Current Voice" : "Select Voice", systemImage: model.currentVoice == selection ? "checkmark.circle.fill" : "circle") }
                        .accessibilityIdentifier("voiceCurrentIndicator")
                    if let voice {
                        HStack {
                            StudioIcon("Play", symbol: "play.fill") { model.playVoiceReference(voice) }
                            StudioShare(model: model, audio: voice.referenceAudio)
                        }
                        StudioIcon("Favorite", symbol: voice.isFavorite ? "star.fill" : "star") { model.setSavedVoiceFavorite(id: voice.id, isFavorite: !voice.isFavorite) }
                    }
                }
                Section {
                    Button { model.selectVoice(selection); cards.push(.imitation) } label: { Label("Imitate", systemImage: "person.wave.2") }.accessibilityIdentifier("voiceImitateButton")
                }
                Section("Voice Shaping") {
                    LabeledContent("Speed", value: String(format: "%.2f×", profile.speed))
                    Slider(value: profileBinding(\.speed), in: 0.5...2, step: 0.05).accessibilityLabel("Speed").accessibilityIdentifier("voiceSpeedSlider")
                    LabeledContent("Pitch", value: String(format: "%.0f", profile.pitch))
                    Slider(value: profileBinding(\.pitch), in: -1200...1200, step: 50).accessibilityLabel("Pitch").accessibilityIdentifier("voicePitchSlider")
                }
                Section {
                    if !languages.isEmpty {
                        Button { cards.push(.voiceOption(selection, false)) } label: { LabeledContent("Language", value: displayLanguage(profile.language) + " ›") }
                            .accessibilityIdentifier("voiceLanguageButton")
                    } else { LabeledContent("Language", value: displayLanguage(profile.language)) }
                    if selection != .tinyLocal {
                        Button { cards.push(.voiceOption(selection, true)) } label: { LabeledContent("Accent", value: displayAccent(profile.accent) + " ›") }
                            .accessibilityIdentifier("voiceAccentButton")
                    } else if let accent = profile.accent { LabeledContent("Accent", value: displayAccent(accent)) }
                }
                if let voice {
                    Section {
                        TextField("Voice Name", text: $name).accessibilityIdentifier("renameVoiceField")
                        StudioIcon("Rename", symbol: "pencil") { model.renameSavedVoice(id: voice.id, name: name) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if model.isLocalSpeechReady || model.isAdvancedPackInstalled {
                            Picker("Rendering Preference", selection: profileBinding(\.renderingPreference)) {
                                Text("Standard").tag(VoiceRenderingPreference.automatic)
                                Text("Advanced Local Voice").tag(VoiceRenderingPreference.advancedLocal)
                            }
                        }
                        StudioIcon("Delete Voice…", symbol: "trash") { deleting = true }.tint(.red)
                    }
                } else {
                    Section {
                        TextField("Preview Text", text: $name)
                        Button("Preview") { model.selectVoice(selection); Task { let previous = model.generatedAudio?.id; await model.generateCurrentVoice(text: name, preview: true); if model.generatedAudio?.id != previous { model.playGeneratedAudio() } } }
                            .disabled(model.isGeneratingSpeech || name.isEmpty)
                        if let audio = model.generatedAudio, audio.sourceVoice == source {
                            StudioShare(model: model, audio: audio)
                        }
                    }
                }
            }.padding(20) }.accessibilityIdentifier("voiceDetailFloatingCard")
                .onAppear { name = voice?.name ?? String(localized: "Hello.", locale: locale) }
                .task(id: profile.language) { if selection.savedVoiceID != nil { await model.probeSystemAccents(profile.language) } }
                .confirmationDialog("Delete Voice?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { if let voice { model.deleteSavedVoice(id: voice.id) } }
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
        return Array(Set(model.usableSystemVoices.filter { SystemVoiceCatalog.baseLanguage($0.language) == SystemVoiceCatalog.baseLanguage(profile.language) }.map(\.language))).sorted()
    }
    private func displayLanguage(_ language: String) -> String { locale.localizedString(forLanguageCode: language) ?? language }
    private func displayAccent(_ accent: String?) -> String { accent.map { locale.localizedString(forIdentifier: $0) ?? $0 } ?? "—" }
}

struct StudioAudioLibrary: View {
    @ObservedObject var model: VoiceStudioModel
    var choosingPerformance = false
    @EnvironmentObject private var cards: FloatingCardStack
    var body: some View {
        StudioFloatingCard(title: "Generation History") {
            ScrollView { VStack(spacing: 12) {
                ForEach(model.pagedGeneratedAudio) { audio in
                    Button { if choosingPerformance { model.usePerformance(audio); cards.pop() } else { cards.push(.audio(audio.id)) } } label: {
                        HStack { VStack(alignment: .leading) { Text(audio.displayName).font(.headline); Text(SavedVoiceLibrary.formattedDuration(audio.duration)).font(.caption) }; Spacer(); Image(systemName: choosingPerformance ? "plus.circle" : "chevron.right") }.padding(20).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }.accessibilityIdentifier("generatedAudio-\(audio.id.uuidString)")
                }
                if model.savedGeneratedAudio.isEmpty { Text("No saved audio yet.") }
                if model.generatedAudioPageCount > 1 { HStack { Button("Previous") { model.setGeneratedAudioPage(model.generatedAudioPage - 1) }.disabled(model.generatedAudioPage == 0); Spacer(); Button("Next") { model.setGeneratedAudioPage(model.generatedAudioPage + 1) }.disabled(model.generatedAudioPage + 1 >= model.generatedAudioPageCount) } }
            }.padding(18) }
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
    @EnvironmentObject private var cards: FloatingCardStack
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
                    Button { cards.push(.account) } label: {
                        Label("Account", systemImage: "person.circle")
                        Text("Not signed in").foregroundStyle(.secondary)
                    }.accessibilityIdentifier("accountPlaceholderLink")
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
                Section("Language") {
                    Button { cards.push(.appLanguage) } label: {
                        HStack { Text("App Language"); Spacer(); Text(languagePreference.language.displayName); Image(systemName: "chevron.right") }
                    }.accessibilityIdentifier("appLanguagePicker")
                }.listRowBackground(Rectangle().fill(appearance.skin.material))
                Section("Appearance") {
                    Button { cards.push(.skin) } label: {
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

private struct ImportAudioButton: View {
    @ObservedObject var model: VoiceStudioModel
    var onChoose: () -> Void = {}
    var onImported: (URL) -> Void = { _ in }
    @State private var isImporterPresented = false

    var body: some View {
        Button { onChoose(); isImporterPresented = true } label: {
            VStack { Image(systemName: "square.and.arrow.down").font(.title3); Text("Import Voice").font(.caption) }.frame(maxWidth: .infinity, minHeight: 58)
        }
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
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { model.report(error) }
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


struct StudioVoiceOptions: View {
    @ObservedObject var model: VoiceStudioModel
    let selection: VoiceSelection
    let accent: Bool
    @EnvironmentObject private var cards: FloatingCardStack
    @Environment(\.locale) private var locale
    private var values: [String] {
        let profile = model.profile(for: selection)
        if !accent { return selection.savedVoiceID != nil ? model.availableLanguages(for: selection) : [profile.language] }
        if case .systemVoice = selection { return profile.accent.map { [$0] } ?? [] }
        return Array(Set(model.usableSystemVoices.filter { SystemVoiceCatalog.baseLanguage($0.language) == SystemVoiceCatalog.baseLanguage(profile.language) }.map(\.language))).sorted()
    }
    var body: some View {
        StudioFloatingCard(title: accent ? "Accent" : "Language") {
            ScrollView { VStack {
                ForEach(values, id: \.self) { value in
                    Button {
                        var updated = model.profile(for: selection)
                        if accent { updated.accent = value } else { updated.language = value; updated.accent = nil }
                        model.updateProfile(updated, for: selection); cards.pop()
                    } label: {
                        HStack { Text(accent ? (locale.localizedString(forIdentifier: value) ?? value) : (locale.localizedString(forLanguageCode: value) ?? value)); Spacer(); if value == (accent ? model.profile(for: selection).accent : model.profile(for: selection).language) { Image(systemName: "checkmark") } }.padding(18)
                    }
                }
                if values.isEmpty { Text("No available options.").padding() }
            } }.accessibilityIdentifier(accent ? "voiceAccentFloatingCard" : "voiceLanguageFloatingCard")
        }
    }
}
struct StudioAudioDetail: View {
    @ObservedObject var model: VoiceStudioModel
    let id: UUID
    @State private var name = ""
    @State private var deleting = false
    var body: some View {
        StudioFloatingCard(title: "Generated Audio") {
            if let audio = model.savedGeneratedAudio.first(where: { $0.id == id }) {
                ScrollView { VStack(alignment: .leading, spacing: 20) {
                    TextField("Audio Name", text: $name).textFieldStyle(.roundedBorder)
                    Text(audio.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    Text(SavedVoiceLibrary.formattedDuration(audio.duration))
                    if let text = audio.text, !text.isEmpty { Text(text) }
                    StudioResult(model: model, audio: audio)
                    HStack {
                        StudioIcon("Rename", symbol: "pencil") { model.renameGeneratedAudio(id: id, name: name) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        StudioIcon("Favorite", symbol: audio.isFavorite ? "star.fill" : "star") { model.setGeneratedAudioFavorite(id: id, isFavorite: !audio.isFavorite) }
                        Spacer(); StudioIcon("Delete Audio…", symbol: "trash") { deleting = true }.tint(.red)
                    }
                }.padding(22) }.onAppear { name = audio.displayName }
                    .confirmationDialog("Delete Audio?", isPresented: $deleting, titleVisibility: .visible) { Button("Delete", role: .destructive) { model.deleteGeneratedAudio(id: id) } }
                    .accessibilityIdentifier("generatedAudioFloatingCard")
            }
        }
    }
}
struct StudioResult: View {
    @ObservedObject var model: VoiceStudioModel
    let audio: AudioAsset
    var body: some View {
        HStack {
            StudioIcon("Play", symbol: "play.fill") { model.playAudioAsset(audio) }
            StudioIcon("Stop", symbol: "stop.fill") { model.stopPlayback() }
            StudioShare(model: model, audio: audio)
            Spacer()
            if audio.persistenceState != .persistent {
                Button { model.saveGeneratedAudio() } label: { Label("Save Audio", systemImage: "square.and.arrow.down") }.accessibilityIdentifier("saveGeneratedAudioButton")
            } else { Label("Saved", systemImage: "checkmark").font(.caption) }
        }.padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
struct StudioImitation: View {
    @ObservedObject var model: VoiceStudioModel
    @EnvironmentObject private var cards: FloatingCardStack
    @Environment(\.locale) private var locale
    @State private var text = ""
    @State private var importing = false
    var body: some View {
        StudioFloatingCard(title: "Audio Imitation") {
            ScrollView { VStack(alignment: .leading, spacing: 22) {
                Label(model.voiceName(for: model.currentVoice, locale: locale), systemImage: "person.wave.2")
                Text("Reference Audio").font(.headline)
                Text("Use audio up to 30 seconds long.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { if model.isRecording { model.stopRecording() } else { Task { await model.startRecording(performance: true) } } } label: { Label(model.isRecording ? "Stop Recording" : "Record", systemImage: model.isRecording ? "stop.fill" : "mic.fill") }.disabled(model.isRequestingPermission)
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }.disabled(model.isRecording || model.isRequestingPermission)
                }
                Button { cards.push(.history(true)) } label: { Label("Generation History", systemImage: "square.stack") }.accessibilityIdentifier("imitationHistoryButton")
                if let reference = model.performanceReference {
                    HStack { Text(SavedVoiceLibrary.formattedDuration(reference.audio.duration)); StudioIcon("Play", symbol: "play.fill") { model.playAudioAsset(reference.audio) }; StudioIcon("Stop", symbol: "stop.fill") { model.stopPlayback() } }
                }
                TextField("Enter new text (optional)", text: $text, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("imitationTextField")
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Recreate this audio with the current voice." : "Use the current voice and this delivery for new words.").font(.footnote).foregroundStyle(.secondary)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("Imitation with new text is not supported yet.").font(.footnote).foregroundStyle(.secondary) }
                Button { Task { await model.imitate(optionalText: text) } } label: { Label("Imitate", systemImage: "person.wave.2").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent)
                    .disabled(!model.canImitate || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("runImitationButton")
                if model.isGeneratingSpeech { HStack { ProgressView("Preparing…"); StudioIcon("Cancel", symbol: "xmark") { model.cancelGeneration() } } }
                if model.currentVoice.savedVoiceID == nil { Text("Choose a saved voice to imitate.").font(.footnote) }
                if !model.isOpenVoicePackReady { Text("Install the optional voice pack in Settings to imitate.").font(.footnote) }
                if let audio = model.generatedAudio, audio.generationKind == .imitationSameContent { StudioResult(model: model, audio: audio) }
                Text(LocalizedStringKey(model.statusMessage)).font(.footnote)
            }.padding(22) }.fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
                switch result { case .success(let url): model.importPerformance(from: url)
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { model.report(error) } }
            }
        }
    }
}
private final class ShareAudioItem: Identifiable {
    let id = UUID(); let lease: AudioFileLease
    init(lease: AudioFileLease) { self.lease = lease }
}
struct StudioShare: View {
    @ObservedObject var model: VoiceStudioModel
    let audio: AudioAsset
    @State private var item: ShareAudioItem?
    var body: some View {
        StudioIcon("Share", symbol: "square.and.arrow.up") {
            do { item = ShareAudioItem(lease: try model.audioLease(for: audio)) }
            catch { model.statusMessage = "This audio could not be shared. Please try again." }
        }.sheet(item: $item) { item in AudioActivitySheet(item: item) }
    }
}
private struct AudioActivitySheet: UIViewControllerRepresentable {
    let item: ShareAudioItem
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [item.lease.url], applicationActivities: nil)
        // Completion retains the lease even if the originating card is removed.
        controller.completionWithItemsHandler = { [item] _, _, _, _ in item.lease.close() }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
