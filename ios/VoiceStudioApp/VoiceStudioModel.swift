import Combine
import AVFoundation
import Foundation
import VoiceStudioCore

struct CurrentReferenceAudio {
    let asset: AudioAsset
    let source: VoiceSourceType

    var sourceLabel: String {
        switch source {
        case .record: "Recorded"
        case .imported: "Imported"
        case .random: "Random"
        case .builtIn: "Built-in"
        }
    }
}

enum VoiceAvailabilityPolicy {
    static func canSave(hasCurrentReference: Bool, isRecording: Bool, isRequestingPermission: Bool,
                        isSavingVoice: Bool = false) -> Bool {
        hasCurrentReference && !isRecording && !isRequestingPermission && !isSavingVoice
    }
}

enum VoicePreparationState: Equatable {
    case none
    case preparing
    case ready
    case failed
}

enum VoicePreparationRouting {
    static func provider(for selection: VoiceSelection,
                         localCapabilities: CapabilityProfile?) -> SpeechProviderID? {
        guard case .saved = selection,
              let localCapabilities,
              localCapabilities.status(for: .speechGeneration) == .supported,
              localCapabilities.status(for: .voiceCloning) == .supported else { return nil }
        return .local
    }
}

@MainActor
final class VoiceStudioModel: ObservableObject {
    @Published private(set) var currentVoice: CurrentVoiceSelection = .systemDefault
    @Published private(set) var systemVoiceCandidates: [SystemVoiceDescriptor] = []
    @Published private(set) var personalVoiceAuthorization = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    let systemVoiceAvailability: SystemVoiceAvailabilityCache
    private let catalogOverride: [SystemVoiceDescriptor]?
    private let voiceSelectionStore: VoiceSelectionStore
    private var voiceAvailabilitySubscription: AnyCancellable?
    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var microphonePermissionDenied = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isSavingVoice = false
    @Published private(set) var isInstallingLocalSpeech = false
    @Published private(set) var isGeneratingSpeech = false
    @Published private(set) var isResolvingVoice = false
    @Published private(set) var isDownloadingTinyLocalVoice = false
    @Published private(set) var isLocalSpeechReady = false
    @Published private(set) var isTinyLocalModelReady = false
    @Published private(set) var isDeletingTinyLocalModel = false
    @Published private(set) var isOpenVoicePackReady = false
    @Published private(set) var hasPreparedOpenVoiceReference = false
    @Published private(set) var isInstallingOpenVoicePack = false
    @Published private(set) var isDeletingOpenVoicePack = false
    @Published private(set) var isPreparingOpenVoiceTarget = false
    @Published private(set) var preparedOpenVoiceID: UUID?
    @Published private(set) var voicePreparationState: VoicePreparationState = .none
    @Published private(set) var preparedVoiceID: UUID?
    @Published private(set) var preparationVoiceID: UUID?
    @Published private(set) var generatedAudio: AudioAsset?
    private var generatedAudioCacheKind: AudioCacheKind = .generated
    @Published private(set) var savedGeneratedAudio: [AudioAsset] = []
    @Published private(set) var generatedAudioPage = 0
    @Published private(set) var currentReference: CurrentReferenceAudio?
    @Published private(set) var savedVoices: [VoiceAsset] = []
    @Published private(set) var mostRecentlySavedVoiceID: UUID?
    @Published private(set) var savedVoiceFilter: SavedVoiceFilter = .time
    @Published private(set) var savedVoicePage = 0
    @Published var statusMessage = "Choose a voice and enter text to generate speech."
    let diagnostics: VoiceStudioDiagnostics

    var isReferenceReady: Bool { currentReference != nil }
    var canSaveVoice: Bool {
        VoiceAvailabilityPolicy.canSave(hasCurrentReference: isReferenceReady,
                                        isRecording: isRecording,
                                        isRequestingPermission: isRequestingPermission,
                                        isSavingVoice: isSavingVoice)
    }
    var filteredSavedVoices: [VoiceAsset] {
        SavedVoiceLibrary.voices(savedVoices, matching: savedVoiceFilter)
    }
    var pagedSavedVoices: [VoiceAsset] {
        SavedVoiceLibrary.page(filteredSavedVoices, index: savedVoicePage)
    }
    var savedVoicePageCount: Int { SavedVoiceLibrary.pageCount(for: filteredSavedVoices.count) }
    var pagedGeneratedAudio: [AudioAsset] { GeneratedAudioLibrary.page(savedGeneratedAudio, index: generatedAudioPage) }
    var generatedAudioPageCount: Int { GeneratedAudioLibrary.pageCount(for: savedGeneratedAudio.count) }

    func preparationState(for selection: VoiceSelection) -> VoicePreparationState {
        guard let id = selection.savedVoiceID else { return .none }
        guard preparedVoiceID == id || preparationVoiceID == id else { return .none }
        return voicePreparationState
    }

    private let audioFileStore: AudioFileStore
    private let audioLifecycle: AudioLifecycle
    private let providers: [SpeechProviderID: any SpeechProvider]
    private let localPackProvider: any InstallableSpeechProvider
    private let voicePreparingProvider: (any VoicePreparingSpeechProvider)?
    private let timePitchProcessor = AudioTimePitchProcessor()
    private let openVoicePackStore: OpenVoicePackStore
    private let openVoiceConverter: any VoiceConverterProvider

    private let recorder: any AudioRecording
    private let importer: any AudioImporting
    private let player: AudioPlayer

    init(rootDirectory: URL? = nil,
         microphonePermissionClient: (any MicrophonePermissionClient)? = nil,
         audioRecorder: (any AudioRecording)? = nil,
         audioImporter: (any AudioImporting)? = nil,
         providerAssembly: SpeechProviderAssembly? = nil,
         diagnostics suppliedDiagnostics: VoiceStudioDiagnostics? = nil,
         systemVoices: [SystemVoiceDescriptor]? = nil,
         voiceAvailability: SystemVoiceAvailabilityCache? = nil,
         voiceConverter: (any VoiceConverterProvider)? = nil) throws {
        let storeRoot: URL
        if let rootDirectory {
            storeRoot = rootDirectory
        } else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
            storeRoot = support.appendingPathComponent("VoiceStudio", isDirectory: true)
        }
        let fileStore = try AudioFileStore(rootDirectory: storeRoot)
        self.audioFileStore = fileStore
        self.catalogOverride = systemVoices
        self.systemVoiceAvailability = voiceAvailability ?? SystemVoiceAvailabilityCache()
        self.openVoiceConverter = voiceConverter ?? OpenVoiceCoreMLConverter()
        self.voiceSelectionStore = VoiceSelectionStore(root: storeRoot)
        self.audioLifecycle = AudioLifecycle(fileStore: fileStore)
        self.openVoicePackStore = OpenVoicePackStore(rootDirectory: storeRoot.appendingPathComponent("RendererPacks", isDirectory: true))
        let diagnostics = suppliedDiagnostics ?? VoiceStudioDiagnostics()
        let assembly = providerAssembly ?? SpeechProviderAssembly.production(diagnostics: diagnostics)
        self.diagnostics = diagnostics
        self.providers = assembly.providers
        self.localPackProvider = assembly.localPackProvider
        self.voicePreparingProvider = assembly.localPackProvider as? any VoicePreparingSpeechProvider

        let activeRecorder = audioRecorder ?? AudioRecorder(fileStore: fileStore,
                                                            microphonePermissionClient: microphonePermissionClient)
        self.recorder = activeRecorder
        self.importer = audioImporter ?? AudioImporter(fileStore: fileStore)
        self.player = AudioPlayer(fileStore: fileStore)
        self.savedVoices = SavedVoiceLibrary.voices(fileStore.savedVoices(), matching: .time)
        self.savedGeneratedAudio = GeneratedAudioLibrary.assets(fileStore.savedAudioAssets())
        self.currentVoice = voiceSelectionStore.current
        if let id = currentVoice.savedVoiceID, !savedVoices.contains(where: { $0.id == id }) {
            currentVoice = savedVoices.first.map { .saved($0.id) } ?? .systemDefault
            try voiceSelectionStore.select(currentVoice)
        }
        refreshSystemVoiceCatalog()
        voiceAvailabilitySubscription = systemVoiceAvailability.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        systemVoiceAvailability.onInvalidation = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshSystemVoiceCatalog()
                await self.restoreCurrentVoiceAvailability()
            }
        }
        self.player.stateHandler = { [weak self] playing in self?.isPlaying = playing }
        activeRecorder.interruptionHandler = { [weak self] result in
            guard let self else { return }
            self.isRecording = false
            switch result {
            case .success(let asset):
                self.setCurrentReference(asset, source: .record)
                self.statusMessage = "Recording stopped by an audio interruption. The reference is ready to play or save as a voice."
            case .failure(let error):
                self.statusMessage = error.localizedDescription
            }
        }
    }

    var usableSystemVoices: [SystemVoiceDescriptor] { systemVoiceAvailability.usable(systemVoiceCandidates) }
    func refreshSystemVoiceCatalog() {
        personalVoiceAuthorization = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        systemVoiceCandidates = (catalogOverride ?? AVSpeechSynthesisVoice.speechVoices().map(SystemVoiceDescriptor.init)).filter {
            !$0.isPersonal || personalVoiceAuthorization == .authorized
        }
    }
    func authorizePersonalVoice() async {
        _ = await withCheckedContinuation { continuation in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in continuation.resume(returning: status) }
        }
        systemVoiceAvailability.invalidate()
        refreshSystemVoiceCatalog()
    }
    func probeSystemLanguage(_ language: String, all: Bool = false) async {
        let candidates = SystemVoiceCatalog.rankVoices(systemVoiceCandidates.filter { SystemVoiceCatalog.baseLanguage($0.language) == language }, locale: .autoupdatingCurrent)
        await systemVoiceAvailability.test(all ? candidates : Array(candidates.prefix(8)))
    }
    func restoreCurrentVoiceAvailability() async {
        let restoring = currentVoice
        if case .saved(let id) = currentVoice, savedVoices.contains(where: { $0.id == id }) { return }
        if case .tinyLocal = currentVoice, isTinyLocalModelReady { return }
        if case .systemVoice(let id) = currentVoice, let voice = systemVoiceCandidates.first(where: { $0.identifier == id }) {
            await systemVoiceAvailability.test([voice])
            guard currentVoice == restoring else { return }
            if systemVoiceAvailability.results[id] == .usable { return }
        }
        if let voice = savedVoices.first { selectVoice(.saved(voice.id)); return }
        let language = SystemVoiceCatalog.baseLanguage(Locale.preferredLanguages.first ?? "en")
        await probeSystemLanguage(language)
        guard currentVoice == restoring else { return }
        var candidates = usableSystemVoices.filter { SystemVoiceCatalog.baseLanguage($0.language) == language }
        if candidates.isEmpty, language != "en" {
            await probeSystemLanguage("en")
            guard currentVoice == restoring else { return }
            candidates = usableSystemVoices.filter { SystemVoiceCatalog.baseLanguage($0.language) == "en" }
        }
        if let voice = SystemVoiceCatalog.rankVoices(candidates, locale: .autoupdatingCurrent).first { selectVoice(.systemVoice(voice.identifier)) }
    }
    func selectVoice(_ selection: CurrentVoiceSelection) {
        if let id = selection.savedVoiceID, !savedVoices.contains(where: { $0.id == id }) { return }
        do { try voiceSelectionStore.select(selection); currentVoice = selection }
        catch { report(error) }
    }
    func profile(for selection: VoiceSelection) -> VoiceProfile {
        switch selection {
        case .saved(let id): return savedVoices.first(where: { $0.id == id })?.profile ?? VoiceProfile()
        case .systemVoice(let id):
            if let profile = voiceSelectionStore.profile(identifier: id) { return profile }
            let tag = systemVoiceCandidates.first(where: { $0.identifier == id })?.language ?? "en-US"
            return VoiceProfile(language: SystemVoiceCatalog.baseLanguage(tag), accent: tag)
        case .tinyLocal: return voiceSelectionStore.profile(identifier: "tiny-local") ?? VoiceProfile(language: "en")
        case .systemDefault: return voiceSelectionStore.profile(identifier: "system-default") ?? VoiceProfile()
        }
    }
    var currentVoiceProfile: VoiceProfile { profile(for: currentVoice) }
    var isAdvancedPackInstalled: Bool {
        FileManager.default.fileExists(atPath: localPackProvider.installedResourceURL.appendingPathComponent("manifest.json").path)
    }
    func updateProfile(_ profile: VoiceProfile, for selection: VoiceSelection) {
        guard profile.isValid else { return }
        do {
            if let id = selection.savedVoiceID {
                let updated = try audioFileStore.updateVoiceProfile(id: id, profile: profile)
                savedVoices = savedVoices.map { $0.id == id ? updated : $0 }
            } else {
                let key: String = switch selection { case .systemVoice(let id): id; case .tinyLocal: "tiny-local"; default: "system-default" }
                try voiceSelectionStore.saveProfile(profile, identifier: key)
                objectWillChange.send()
            }
        } catch { report(error) }
    }
    func voiceName(for selection: VoiceSelection, locale: Locale = .autoupdatingCurrent) -> String {
        switch selection {
        case .saved(let id): savedVoices.first(where: { $0.id == id })?.name ?? String(localized: "My Voice", locale: locale)
        case .systemVoice(let id): systemVoiceCandidates.first(where: { $0.identifier == id })?.name ?? String(localized: "System Voice", locale: locale)
        case .tinyLocal: String(localized: "Local Voice", locale: locale)
        case .systemDefault: String(localized: "System Voice", locale: locale)
        }
    }
    var canGenerateCurrentVoice: Bool {
        guard !isResolvingVoice else { return false }
        if let id = currentVoice.savedVoiceID {
            guard let voice = savedVoices.first(where: { $0.id == id }), managedURL(for: voice.referenceAudio) != nil else { return false }
            return voice.profile.renderingPreference == .advancedLocal ? (isLocalSpeechReady || isAdvancedPackInstalled) : isOpenVoicePackReady && openVoiceConverter.capabilities.supports(language: voice.profile.language)
        }
        switch currentVoice {
        case .systemVoice(let id): return systemVoiceAvailability.results[id] == .usable
        case .tinyLocal: return isTinyLocalModelReady
        default: return false
        }
    }
    func generateCurrentVoice(text: String, preview: Bool = false) async {
        let selection = currentVoice
        let profile = currentVoiceProfile
        guard !isGeneratingSpeech, !isResolvingVoice, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isResolvingVoice = true
        defer {
            isResolvingVoice = false
            diagnostics.update { $0.physicalFootprintMB = VoiceStudioDiagnostics.physicalFootprintMB() }
        }
        if selection.savedVoiceID != nil, profile.renderingPreference == .automatic {
            guard isOpenVoicePackReady else { statusMessage = "Install the optional voice pack in Settings to generate with this voice."; return }
            await probeSystemLanguage(profile.language)
            if !usableSystemVoices.contains(where: { SystemVoiceCatalog.baseLanguage($0.language) == profile.language }) { await probeSystemLanguage(profile.language, all: true) }
            let ranked = SystemVoiceCatalog.rankVoices(usableSystemVoices.filter { SystemVoiceCatalog.baseLanguage($0.language) == profile.language },
                                                       locale: Locale(identifier: profile.accent ?? profile.language))
            guard let source = ranked.first else { statusMessage = "No usable system voice is available for this language."; return }
            diagnostics.update { $0.systemVoiceIdentifier = source.identifier; $0.systemVoiceQuality = source.quality; $0.voiceSource = "Saved Voice" }
            await generateOpenVoiceSpeech(text: text, target: selection, systemSource: .systemVoice(source.identifier),
                                          language: profile.language, accent: profile.accent, speed: profile.speed, pitch: profile.pitch,
                                          cacheKind: preview ? .preview : .generated)
        } else {
            if selection.savedVoiceID == nil { await activateVoice(selection) }
            if selection.savedVoiceID != nil {
                await restoreLocalSpeechProvider()
                await prepareVoice(selection, language: profile.language)
            }
            if case .systemVoice(let id) = selection {
                guard let voice = systemVoiceCandidates.first(where: { $0.identifier == id }) else { return }
                await systemVoiceAvailability.test([voice])
                guard systemVoiceAvailability.results[id] == .usable else { statusMessage = "This voice is unavailable. Please select another voice."; return }
                diagnostics.update { $0.systemVoiceIdentifier = id; $0.systemVoiceQuality = voice.quality; $0.voiceSource = voice.isPersonal ? "Personal Voice" : "System Voice" }
            }
            updateDiagnosticContext(voice: selection, language: profile.language, accent: profile.accent, hasText: true, hasCurrentReference: false)
            if selection == .tinyLocal { diagnostics.update { $0.voiceSource = "Local Voice"; $0.systemVoiceIdentifier = nil; $0.systemVoiceQuality = nil } }
            await generateSpeech(text: text, voice: selection, language: profile.language, accent: profile.accent, speed: profile.speed, pitch: profile.pitch,
                                 cacheKind: preview ? .preview : .generated)
        }
    }

    func startRecording() async {
        guard !isRecording, !isRequestingPermission else { return }
        stopPlayback()
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        do {
            try await recorder.startRecording()
            microphonePermissionDenied = false
            isRecording = true
            statusMessage = "Recording. Tap Stop recording when you are done."
        } catch {
            isRecording = false
            if let studioError = error as? VoiceStudioError,
               studioError == .microphonePermissionDenied {
                microphonePermissionDenied = true
                statusMessage = "Microphone access is off. Open Settings and allow microphone access to record a voice reference."
                return
            }
            statusMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        do {
            let asset = try recorder.stopRecording()
            setCurrentReference(asset, source: .record)
            isRecording = false
            statusMessage = "Recording ready in Voice Studio. Play it or save it as a voice reference."
        } catch {
            isRecording = false
            statusMessage = error.localizedDescription
        }
    }

    func importAudio(from url: URL) {
        guard !isRecording, !isRequestingPermission else { return }
        do {
            let asset = try importer.importDocument(at: url)
            setCurrentReference(asset, source: .imported)
            statusMessage = "An app-managed copy is ready to play or save as a voice reference."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func playCurrentAudio() {
        guard let currentReference else { return }
        play(currentReference.asset)
    }

    func playVoiceReference(_ voice: VoiceAsset) { play(voice.referenceAudio) }

    func capabilities(for selection: VoiceSelection, usingVoiceConverter: Bool = false) -> CapabilityProfile {
        if usingVoiceConverter || (selection.savedVoiceID != nil && profile(for: selection).renderingPreference == .automatic) {
            guard selection.savedVoiceID != nil, isOpenVoicePackReady,
                  let system = providers[.system]?.capabilities else { return CapabilityProfile() }
            var support = system.support
            support[.voiceConversion] = openVoiceConverter.capabilities.status(for: .voiceConversion)
            support[.voiceCloning] = .supported
            support[.speed] = .supported; support[.pitch] = .supported
            return CapabilityProfile(support: support, shaping: [:],
                                     expressions: system.expressions,
                                     languages: system.languages.filter { openVoiceConverter.capabilities.supports(language: $0) },
                                     accentsByLanguage: system.accentsByLanguage)
        }
        let providerID: SpeechProviderID = switch selection {
        case .systemDefault, .systemVoice: .system
        case .tinyLocal: .tinyLocal
        case .saved: .local
        }
        guard let provider = providers[providerID] else { return CapabilityProfile() }
        var support = provider.capabilities.support
        var shaping = provider.capabilities.shaping
        if support[.speechGeneration] == .supported {
            support[.speed] = .supported
            support[.pitch] = .supported
            shaping = [:]
        }
        return CapabilityProfile(support: support, shaping: shaping,
                                 expressions: provider.capabilities.expressions,
                                 languages: provider.capabilities.languages,
                                 accentsByLanguage: provider.capabilities.accentsByLanguage)
    }

    func availableLanguages(for selection: VoiceSelection, usingVoiceConverter: Bool = false) -> [String] {
        capabilities(for: selection, usingVoiceConverter: usingVoiceConverter).languages
    }

    func availableAccents(for selection: VoiceSelection, language: String?,
                          usingVoiceConverter: Bool = false) -> [String] {
        capabilities(for: selection, usingVoiceConverter: usingVoiceConverter).accents(for: language)
    }

    func canGenerate(text: String, voice: VoiceSelection, language: String,
                     usingVoiceConverter: Bool = false) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if usingVoiceConverter {
            guard let voiceID = voice.savedVoiceID, isOpenVoicePackReady,
                  savedVoices.contains(where: { $0.id == voiceID }),
                  let system = providers[.system]?.capabilities else { return false }
            return SpeechProviderSelection.select(
                voice: voice, language: language, system: system,
                local: providers[.local]?.capabilities, localIsReady: isLocalSpeechReady,
                tinyLocal: providers[.tinyLocal]?.capabilities,
                tinyLocalIsReady: providers[.tinyLocal] != nil,
                voiceConverter: openVoiceConverter.capabilities,
                voiceConverterIsReady: true, useVoiceConverter: true) == .voiceConverter
        }
        if let voiceID = voice.savedVoiceID, preparedVoiceID != voiceID { return false }
        return SpeechProviderSelection.select(voice: voice, language: language,
                                              system: providers[.system]?.capabilities ?? CapabilityProfile(),
                                              local: providers[.local]?.capabilities,
                                              localIsReady: isLocalSpeechReady,
                                              tinyLocal: providers[.tinyLocal]?.capabilities,
                                              tinyLocalIsReady: providers[.tinyLocal] != nil) != nil
    }

    func restoreLocalSpeechProvider() async {
        guard !isLocalSpeechReady, !isInstallingLocalSpeech else { return }
        let installed = localPackProvider.installedResourceURL
        guard FileManager.default.fileExists(atPath: installed.appendingPathComponent("manifest.json").path) else { return }
        await installLocalSpeechResource(from: installed)
    }

    func refreshTinyLocalModelState() async {
        guard let tinyProvider = providers[.tinyLocal] as? KittenLocalSpeechProvider else { return }
        isTinyLocalModelReady = await tinyProvider.isInstalled()
    }

    func installTinyLocalVoice() async {
        guard !isGeneratingSpeech, !isDownloadingTinyLocalVoice, let provider = providers[.tinyLocal] as? KittenLocalSpeechProvider else { return }
        isDownloadingTinyLocalVoice = true
        defer { isDownloadingTinyLocalVoice = false }
        do { try await provider.install(); await refreshTinyLocalModelState(); selectVoice(.tinyLocal) }
        catch { statusMessage = "Local voice could not be downloaded. Please try again." }
    }

    func refreshOpenVoicePackState() async {
        let packStore = openVoicePackStore
        let filesValid = await Task.detached(priority: .utility) {
            (try? packStore.validateInstalled()) != nil
        }.value
        guard filesValid else {
            isOpenVoicePackReady = false
            preparedOpenVoiceID = nil
            hasPreparedOpenVoiceReference = false
            return
        }
        do {
            try await openVoiceConverter.validateModels(packDirectory: packStore.installedPackURL,
                                                        cacheDirectory: packStore.cacheDirectory)
            isOpenVoicePackReady = true
        } catch {
            isOpenVoicePackReady = false
            preparedOpenVoiceID = nil
            hasPreparedOpenVoiceReference = false
        }
    }

    func installOpenVoicePack(from folder: URL) async {
        guard !isInstallingOpenVoicePack, !isGeneratingSpeech else { return }
        let didStartScope = folder.startAccessingSecurityScopedResource()
        defer { if didStartScope { folder.stopAccessingSecurityScopedResource() } }
        isInstallingOpenVoicePack = true
        defer { isInstallingOpenVoicePack = false }
        let packStore = openVoicePackStore
        do {
            try await Task.detached(priority: .userInitiated) { try packStore.install(from: folder) }.value
            preparedOpenVoiceID = nil
            try? FileManager.default.removeItem(at: packStore.cacheDirectory)
            hasPreparedOpenVoiceReference = false
            try await openVoiceConverter.validateModels(packDirectory: packStore.installedPackURL,
                                                        cacheDirectory: packStore.cacheDirectory)
            isOpenVoicePackReady = true
            statusMessage = "OpenVoice pack installed and validated."
        } catch {
            isOpenVoicePackReady = false
            preparedOpenVoiceID = nil
            hasPreparedOpenVoiceReference = false
            statusMessage = "OpenVoice pack is invalid or incompatible."
        }
    }

    func deleteOpenVoicePack() async {
        guard !isDeletingOpenVoicePack, !isGeneratingSpeech, !isPreparingOpenVoiceTarget else { return }
        isDeletingOpenVoicePack = true
        defer { isDeletingOpenVoicePack = false }
        let packStore = openVoicePackStore
        do {
            try await Task.detached(priority: .userInitiated) { try packStore.deleteInstalledPack() }.value
            isOpenVoicePackReady = false
            preparedOpenVoiceID = nil
            hasPreparedOpenVoiceReference = false
            statusMessage = "OpenVoice pack and disposable speaker cache removed."
        } catch {
            statusMessage = "Could not remove OpenVoice pack. Please try again."
        }
    }

    func prepareOpenVoiceTarget(_ selection: VoiceSelection) async {
        guard !isGeneratingSpeech, !isPreparingOpenVoiceTarget else { return }
        guard let voiceID = selection.savedVoiceID,
              let voice = savedVoices.first(where: { $0.id == voiceID }),
              isOpenVoicePackReady else {
            statusMessage = "Choose a saved voice and validate the optional converter pack first."
            return
        }
        if isLocalSpeechReady, let runtimeManager = localPackProvider as? any SpeechRuntimeManaging {
            isLocalSpeechReady = false
            await runtimeManager.unloadRuntime()
        }
        await prepareOpenVoiceReference(voice)
    }

    private func prepareOpenVoiceReference(_ voice: VoiceAsset) async {
        guard isOpenVoicePackReady else { return }
        if preparedOpenVoiceID == voice.id, hasPreparedOpenVoiceReference { return }
        isPreparingOpenVoiceTarget = true
        preparedOpenVoiceID = nil
        hasPreparedOpenVoiceReference = false
        defer { isPreparingOpenVoiceTarget = false }
        do {
            let referenceURL = try audioFileStore.managedURL(for: voice.referenceAudio)
            try await openVoiceConverter.prepareReference(
                referenceURL: referenceURL, voiceID: voice.id, referenceAudioID: voice.referenceAudio.id,
                packDirectory: openVoicePackStore.installedPackURL,
                cacheDirectory: openVoicePackStore.cacheDirectory)
            preparedOpenVoiceID = voice.id
            hasPreparedOpenVoiceReference = true
            statusMessage = "Saved voice is ready for the experimental converter."
        } catch {
            preparedOpenVoiceID = nil
            hasPreparedOpenVoiceReference = false
            statusMessage = "Could not prepare this voice for experimental conversion."
        }
    }

    func deleteTinyLocalModel() async {
        guard !isDeletingTinyLocalModel, !isGeneratingSpeech,
              let tinyProvider = providers[.tinyLocal] as? KittenLocalSpeechProvider else { return }
        isDeletingTinyLocalModel = true
        defer { isDeletingTinyLocalModel = false }
        do {
            try await tinyProvider.deleteInstalledPack()
            isTinyLocalModelReady = false
            diagnostics.update {
                $0.runtime = "not loaded"
                $0.rendererLoadDurationMilliseconds = nil
                $0.rendererGenerationDurationMilliseconds = nil
            }
            statusMessage = "Local voice data removed."
            if currentVoice == .tinyLocal { await restoreCurrentVoiceAvailability() }
        } catch {
            statusMessage = "Could not remove local voice data. Please try again."
        }
    }

    func installLocalSpeechResource(from folder: URL) async {
        guard !isInstallingLocalSpeech, !isGeneratingSpeech else { return }
        isInstallingLocalSpeech = true
        defer { isInstallingLocalSpeech = false }
        do {
            _ = try await localPackProvider.installPack(at: folder)
            isLocalSpeechReady = true
            if voicePreparationState != .preparing {
                preparedVoiceID = nil
                preparationVoiceID = nil
                voicePreparationState = .none
            }
            statusMessage = "Local speech is ready."
        } catch {
            isLocalSpeechReady = false
            let hasRecordedFailure = diagnostics.stages.contains {
                [.packValidation, .packImport, .runtimeLoad].contains($0.stage) && $0.state == .failed
            }
            if !hasRecordedFailure {
                diagnostics.update { $0.runtime = "failed" }
                diagnostics.finish(.runtimeLoad, startedAt: ProcessInfo.processInfo.systemUptime - 0.001,
                                   error: error, friendlyError: "Could not load local speech. Please try again.")
            }
            statusMessage = "Could not load local speech. Please try again."
        }
    }

    func prepareVoice(_ selection: VoiceSelection, language: String) async {
        guard let voiceID = selection.savedVoiceID else { return }
        guard VoicePreparationRouting.provider(for: selection, localCapabilities: providers[.local]?.capabilities) == .local,
              let voice = savedVoices.first(where: { $0.id == voiceID }),
              let voicePreparingProvider else {
            voicePreparationState = .failed
            statusMessage = "This saved voice cannot be prepared by the available voice renderer."
            return
        }
        if preparedVoiceID == voiceID, voicePreparationState == .ready { return }
        preparedVoiceID = nil
        preparationVoiceID = voiceID
        voicePreparationState = .preparing
        diagnostics.update {
            $0.provider = "Advanced local"; $0.rendererID = "Qwen3-TTS"; $0.backend = "CPU"
            $0.voice = "saved voice · \(voice.id.uuidString.prefix(8))"; $0.reference = "preparing"
        }
        diagnostics.beginVoicePrepare(provider: SpeechProviderID.local.rawValue,
                                      renderer: "Qwen3-TTS", voiceID: voiceID,
                                      referenceFormat: "managed audio asset",
                                      runtimeLoaded: isLocalSpeechReady,
                                      physicalFootprintMB: nil)
        let started = ProcessInfo.processInfo.systemUptime
        diagnostics.start(.voicePrepare)
        do {
            if !isLocalSpeechReady {
                diagnostics.updateVoicePrepareOperation("runtimeLoad")
                await restoreLocalSpeechProvider()
            }
            guard isLocalSpeechReady else {
                throw NSError(domain: "VoiceStudio.Prepare", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The local voice renderer is not available. Import its model pack in Developer Tools and retry."])
            }
            diagnostics.updateVoicePrepareOperation("resolveProvider", runtimeLoaded: true)
            diagnostics.updateVoicePrepareOperation("validateReference")
            let referenceURL = try audioFileStore.managedURL(for: voice.referenceAudio)
            guard FileManager.default.fileExists(atPath: referenceURL.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: referenceURL.path),
                  let bytes = (attributes[.size] as? NSNumber)?.intValue, bytes > 0 else {
                throw VoiceStudioError.missingManagedAudio
            }
            let referenceFormat = "managed reference asset · \(bytes) bytes"
            diagnostics.updateVoicePrepareOperation("prepareReference", runtimeLoaded: true,
                                                    referenceFormat: referenceFormat)
            try await voicePreparingProvider.prepareVoice(voice, referenceAudioURL: referenceURL)
            preparedVoiceID = voiceID
            voicePreparationState = .ready
            diagnostics.update { $0.reference = "ready"; $0.language = language }
            diagnostics.finish(.voicePrepare, startedAt: started)
            diagnostics.finishVoicePrepare(.success)
            statusMessage = "Voice is ready."
        } catch {
            voicePreparationState = .failed
            preparedVoiceID = nil
            diagnostics.update { $0.reference = "failed" }
            diagnostics.finish(.voicePrepare, startedAt: started, error: error,
                               friendlyError: "Could not prepare this voice. Please try again.")
            diagnostics.finishVoicePrepare(.failed)
            statusMessage = "Could not prepare this voice. Please try again."
        }
    }

    func activateVoice(_ selection: VoiceSelection) async {
        guard selection.savedVoiceID == nil else { return }
        preparedOpenVoiceID = nil
        hasPreparedOpenVoiceReference = false
        let wasRuntimeLoaded = isLocalSpeechReady
        isLocalSpeechReady = false
        preparedVoiceID = nil
        preparationVoiceID = nil
        voicePreparationState = .none
        diagnostics.update { $0.runtime = "not loaded"; $0.reference = "none" }
        if wasRuntimeLoaded,
           let runtimeManager = localPackProvider as? any SpeechRuntimeManaging {
            await runtimeManager.unloadRuntime()
        }
    }

    func updateDiagnosticContext(voice: VoiceSelection, language: String, accent: String?,
                                 hasText: Bool, hasCurrentReference: Bool) {
        diagnostics.update {
            switch voice {
            case .systemDefault:
                $0.provider = "System"; $0.rendererID = nil; $0.backend = "System"; $0.voice = "system"
                $0.rendererLoadDurationMilliseconds = nil; $0.rendererGenerationDurationMilliseconds = nil
            case .systemVoice(let identifier):
                $0.provider = "System"; $0.rendererID = nil; $0.backend = "System"; $0.voice = "system · \(identifier)"
                $0.rendererLoadDurationMilliseconds = nil; $0.rendererGenerationDurationMilliseconds = nil
            case .tinyLocal:
                $0.provider = "Tiny local"; $0.rendererID = "KittenTTS-Nano-int8"
                $0.backend = "ONNX Runtime · CPU"; $0.voice = "built-in"
            case .saved(let id):
                $0.provider = "Advanced local"; $0.rendererID = "Qwen3-TTS"
                $0.backend = "CPU"; $0.voice = "saved voice · \(id.uuidString.prefix(8))"
                $0.rendererLoadDurationMilliseconds = nil; $0.rendererGenerationDurationMilliseconds = nil
            }
            $0.language = language
            $0.accent = accent
            $0.reference = hasCurrentReference ? "selected" : (voice.savedVoiceID == nil ? "none" : (preparedVoiceID == voice.savedVoiceID ? "ready" : "not prepared"))
            $0.request = hasText ? "ready" : "invalid"
        }
    }

    func recordPackImportFailure(_ error: Error) {
        diagnostics.update { $0.pack = "invalid"; $0.runtime = "not loaded" }
        diagnostics.finish(.packValidation, startedAt: ProcessInfo.processInfo.systemUptime - 0.001,
                           error: error, friendlyError: "This local speech component is invalid or incompatible.")
    }

    func reportLocalSpeechImportError(_ error: Error) {
        recordPackImportFailure(error)
        statusMessage = "Could not load local speech. Please try again."
    }

    func generateOpenVoiceSpeech(text: String, target selection: VoiceSelection,
                                 systemSource: VoiceSelection, language: String, accent: String?,
                                 shaping: VoiceShaping = VoiceShaping(), speed: Double = 1,
                                 pitch: Double = 0, cacheKind: AudioCacheKind = .generated) async {
        guard !isGeneratingSpeech, !isPreparingOpenVoiceTarget,
              canGenerate(text: text, voice: selection, language: language, usingVoiceConverter: true),
              systemSource == .systemDefault || isSystemVoiceSelection(systemSource),
              AudioTimePitchProcessor.accepts(speed: speed, pitch: pitch, shaping: shaping),
              let voiceID = selection.savedVoiceID,
              let targetVoice = savedVoices.first(where: { $0.id == voiceID }),
              let systemProvider = providers[.system] else { return }

        let route = SpeechProviderSelection.select(
            voice: selection, language: language, system: systemProvider.capabilities,
            local: providers[.local]?.capabilities, localIsReady: isLocalSpeechReady,
            tinyLocal: providers[.tinyLocal]?.capabilities,
            tinyLocalIsReady: providers[.tinyLocal] != nil,
            voiceConverter: openVoiceConverter.capabilities,
            voiceConverterIsReady: isOpenVoicePackReady, useVoiceConverter: true)
        guard route == .voiceConverter else { return }

        if isLocalSpeechReady { await activateVoice(.systemDefault) }
        isGeneratingSpeech = true
        defer { isGeneratingSpeech = false }
        stopPlayback()
        diagnostics.update {
            $0.provider = "System speech → Voice conversion → Speed/Pitch"
            $0.language = language; $0.accent = accent
            $0.rendererID = "OpenVoice V2 Core ML"
            $0.backend = "Core ML · CPU/GPU"
            $0.generation = "running"
            $0.outputFileName = nil
            $0.outputDuration = nil
            $0.realTimeFactor = nil
            $0.generationDurationMilliseconds = nil
            $0.rendererGenerationDurationMilliseconds = nil
        }
        let started = ProcessInfo.processInfo.systemUptime
        diagnostics.start(.synthesis)
        var activeStage = DiagnosticStage.synthesis
        var activeStageStarted = started
        var temporaryURLs: [URL] = []
        defer { temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) } }
        do {
            let systemRequest = VoiceRequest(text: text, voice: systemSource, language: language,
                                            accent: accent, speed: speed, renderMode: .generate)
            let speechResult = await systemProvider.generate(systemRequest, voice: nil, referenceAudioURL: nil)
            guard case .renderedFile(let rawURL, _, _) = speechResult else {
                throw NSError(domain: "OpenVoice.SourceSpeech", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "System speech could not produce source audio."])
            }
            temporaryURLs.append(rawURL)
            diagnostics.finish(.synthesis, startedAt: started)
            let referenceURL = try audioFileStore.managedURL(for: targetVoice.referenceAudio)
            let conversionStarted = ProcessInfo.processInfo.systemUptime
            activeStage = .voicePrepare; activeStageStarted = conversionStarted
            diagnostics.start(.voicePrepare)
            let convertedURL = try await openVoiceConverter.convert(
                sourceURL: rawURL, targetReferenceURL: referenceURL,
                targetVoiceID: targetVoice.id, targetReferenceID: targetVoice.referenceAudio.id,
                packDirectory: openVoicePackStore.installedPackURL,
                cacheDirectory: openVoicePackStore.cacheDirectory)
            temporaryURLs.append(convertedURL)
            if let timings = await openVoiceConverter.timings() {
                diagnostics.update {
                    $0.openVoiceLoadMilliseconds = timings.loadMilliseconds
                    $0.embeddingPrepareMilliseconds = timings.embeddingMilliseconds
                    $0.conversionMilliseconds = timings.conversionMilliseconds
                }
            }
            let conversionMilliseconds = max(0, Int((ProcessInfo.processInfo.systemUptime - conversionStarted) * 1000))
            diagnostics.finish(.voicePrepare, startedAt: conversionStarted)
            let dspStarted = ProcessInfo.processInfo.systemUptime
            activeStage = .dsp; activeStageStarted = dspStarted
            diagnostics.start(.dsp)
            let shapedURL = try timePitchProcessor.process(convertedURL, speed: speed, pitch: pitch, shaping: shaping)
            diagnostics.finish(.dsp, startedAt: dspStarted)
            if shapedURL != convertedURL { temporaryURLs.append(shapedURL) }
            let output = try AVAudioFile(forReading: shapedURL)
            let duration = Double(output.length) / output.processingFormat.sampleRate
            activeStage = .output; activeStageStarted = ProcessInfo.processInfo.systemUptime
            diagnostics.start(.output)
            let asset = try audioFileStore.registerGeneratedAudio(from: shapedURL, duration: duration,
                                                                  sourceVoiceID: targetVoice.id,
                                                                  sourceVoice: .savedVoice(targetVoice.id),
                                                                  language: language, text: text)
            try audioLifecycle.cache(asset, as: cacheKind)
            generatedAudioCacheKind = cacheKind
            generatedAudio = asset
            let runtimeMilliseconds = max(0, Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
            diagnostics.update {
                $0.generation = "success"
                $0.rendererGenerationDurationMilliseconds = conversionMilliseconds
                $0.generationDurationMilliseconds = runtimeMilliseconds
                $0.outputFileName = asset.fileName
                $0.outputDuration = duration
                $0.realTimeFactor = OpenVoiceRuntimeMetrics.realTimeFactor(
                    elapsedMilliseconds: runtimeMilliseconds, audioDuration: duration)
            }
            diagnostics.finish(.output, startedAt: activeStageStarted)
            statusMessage = "Speech generated."
        } catch {
            diagnostics.finish(activeStage, startedAt: activeStageStarted,
                               error: error,
                               friendlyError: "Voice conversion failed.")
            diagnostics.update { $0.generation = "failed" }
            statusMessage = "This voice could not generate speech. Please try again."
        }
    }

    private func isSystemVoiceSelection(_ selection: VoiceSelection) -> Bool {
        if case .systemVoice = selection { return true }
        return false
    }

    func generateSpeech(text: String, voice selection: VoiceSelection, language: String,
                        accent: String?, shaping: VoiceShaping = VoiceShaping(),
                        expression: VoiceExpression? = nil, speed: Double = 1,
                        pitch: Double = 0, cacheKind: AudioCacheKind = .generated) async {
        guard !isGeneratingSpeech else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            diagnostics.update { $0.request = "invalid"; $0.generation = "failed" }
            return
        }
        if let voiceID = selection.savedVoiceID, preparedVoiceID != voiceID { return }
        guard canGenerate(text: text, voice: selection, language: language) else { return }
        let effectiveCapabilities = capabilities(for: selection)
        guard shaping.values.keys.allSatisfy({ effectiveCapabilities.shaping[$0] != nil && effectiveCapabilities.shaping[$0] != .unsupported }),
              expression.map({ effectiveCapabilities.expressions[$0] != nil && effectiveCapabilities.expressions[$0] != .unsupported }) ?? true,
              effectiveCapabilities.status(for: .speed) == .supported,
              effectiveCapabilities.status(for: .pitch) == .supported else {
            statusMessage = "Some selected voice controls are not available."
            return
        }
        guard AudioTimePitchProcessor.accepts(speed: speed, pitch: pitch, shaping: shaping) else {
            statusMessage = "Some selected voice controls are outside the supported range."
            return
        }
        guard let providerID = SpeechProviderSelection.select(
            voice: selection, language: language,
            system: providers[.system]?.capabilities ?? CapabilityProfile(),
            local: providers[.local]?.capabilities, localIsReady: isLocalSpeechReady,
            tinyLocal: providers[.tinyLocal]?.capabilities,
            tinyLocalIsReady: providers[.tinyLocal] != nil),
              let provider = providers[providerID] else { return }
        let voice = selection.savedVoiceID.flatMap { id in savedVoices.first(where: { $0.id == id }) }
        isGeneratingSpeech = true
        diagnostics.update {
            $0.generation = "running"; $0.outputFileName = nil; $0.outputDuration = nil
            $0.generationDurationMilliseconds = nil; $0.rendererGenerationDurationMilliseconds = nil
            $0.realTimeFactor = nil
        }
        defer { isGeneratingSpeech = false }
        stopPlayback()
        var activeStage: DiagnosticStage?
        var activeStageStartedAt = ProcessInfo.processInfo.systemUptime
        do {
            let requestStarted = ProcessInfo.processInfo.systemUptime
            activeStage = .requestBuild
            activeStageStartedAt = requestStarted
            diagnostics.start(.requestBuild)
            let referenceURL = try voice.map { try audioFileStore.managedURL(for: $0.referenceAudio) }
            let request = VoiceRequest(text: text, voice: selection, language: language,
                                       accent: accent, shaping: shaping, expression: expression,
                                       speed: speed, pitch: pitch, renderMode: .generate)
            diagnostics.finish(.requestBuild, startedAt: requestStarted)
            activeStage = nil
            let synthesisStarted = ProcessInfo.processInfo.systemUptime
            activeStage = .synthesis
            activeStageStartedAt = synthesisStarted
            diagnostics.start(.synthesis)
            let speechResult = await provider.generate(request, voice: voice, referenceAudioURL: referenceURL)
            if providerID == .tinyLocal { await refreshTinyLocalModelState() }
            switch speechResult {
            case .renderedFile(let rawURL, _, _):
                diagnostics.finish(.synthesis, startedAt: synthesisStarted)
                let synthesisMilliseconds = max(0, Int((ProcessInfo.processInfo.systemUptime - synthesisStarted) * 1000))
                diagnostics.update { $0.generationDurationMilliseconds = synthesisMilliseconds }
                activeStage = nil
                defer { try? FileManager.default.removeItem(at: rawURL) }
                let dspStarted = ProcessInfo.processInfo.systemUptime
                activeStage = .dsp
                activeStageStartedAt = dspStarted
                diagnostics.start(.dsp)
                let shapedURL = try timePitchProcessor.process(rawURL, speed: speed, pitch: pitch,
                                                               shaping: shaping)
                diagnostics.finish(.dsp, startedAt: dspStarted)
                activeStage = nil
                defer { if shapedURL != rawURL { try? FileManager.default.removeItem(at: shapedURL) } }
                let outputFile = try AVAudioFile(forReading: shapedURL)
                let duration = Double(outputFile.length) / outputFile.processingFormat.sampleRate
                let outputStarted = ProcessInfo.processInfo.systemUptime
                activeStage = .output
                activeStageStartedAt = outputStarted
                diagnostics.start(.output)
                let source: GeneratedAudioVoiceSource = switch selection {
                case .saved(let id): .savedVoice(id)
                case .systemDefault: .systemVoice(nil)
                case .systemVoice(let id): .systemVoice(id)
                case .tinyLocal: .tinyLocalVoice("tiny-local")
                }
                let asset = try audioFileStore.registerGeneratedAudio(from: shapedURL, duration: duration,
                                                                     sourceVoiceID: voice?.id, sourceVoice: source,
                                                                     language: language, text: text)
                try audioLifecycle.cache(asset, as: cacheKind)
                generatedAudioCacheKind = cacheKind
                generatedAudio = asset
                diagnostics.finish(.output, startedAt: outputStarted)
                activeStage = nil
                diagnostics.update { $0.generation = "success"; $0.outputFileName = asset.fileName; $0.outputDuration = duration }
                let measuredGeneration = providerID == .tinyLocal
                    ? diagnostics.snapshot.rendererGenerationDurationMilliseconds ?? synthesisMilliseconds
                    : synthesisMilliseconds
                diagnostics.update { $0.realTimeFactor = Double(measuredGeneration) / 1000 / max(duration, 0.001) }
                statusMessage = "Speech generated."
            case .failure(let reason):
                let error = NSError(domain: "SpeechProvider.\(providerID.rawValue)", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: reason])
                diagnostics.finish(.synthesis, startedAt: synthesisStarted, error: error,
                                   friendlyError: "Speech generation failed. Please try again.")
                activeStage = nil
                diagnostics.update { $0.generation = "failed" }
                statusMessage = "Speech generation failed. Please try again."
            case .unsupported:
                diagnostics.finish(.synthesis, startedAt: synthesisStarted,
                                   error: NSError(domain: "SpeechProvider", code: 2,
                                                  userInfo: [NSLocalizedDescriptionKey: "Provider reported unsupported capability."]),
                                   friendlyError: "This voice does not support the selected controls.")
                activeStage = nil
                diagnostics.update { $0.generation = "failed" }
                statusMessage = "This voice does not support the selected controls."
            case .audio:
                diagnostics.finish(.synthesis, startedAt: synthesisStarted,
                                   error: NSError(domain: "SpeechProvider", code: 3,
                                                  userInfo: [NSLocalizedDescriptionKey: "Provider returned an audio asset instead of a renderable file."]),
                                   friendlyError: "Generated audio could not be saved. Please try again.")
                activeStage = nil
                diagnostics.update { $0.generation = "failed" }
                statusMessage = "Generated audio could not be saved. Please try again."
            }
        } catch {
            diagnostics.update { $0.generation = "failed" }
            if let activeStage {
                diagnostics.finish(activeStage, startedAt: activeStageStartedAt, error: error,
                                   friendlyError: "Speech generation failed. Please try again.")
            }
            statusMessage = "Speech generation failed. Please try again."
        }
    }

    func playGeneratedAudio() {
        guard let generatedAudio else { return }
        play(generatedAudio)
    }

    func playAudioAsset(_ asset: AudioAsset) { play(asset) }

    func managedURL(for asset: AudioAsset) -> URL? { try? audioFileStore.managedURL(for: asset) }

    func saveGeneratedAudio() {
        guard let generatedAudio, generatedAudio.persistenceState == .temporary else { return }
        do {
            self.generatedAudio = try audioLifecycle.save(id: generatedAudio.id, from: generatedAudioCacheKind)
            savedGeneratedAudio = GeneratedAudioLibrary.assets(audioFileStore.savedAudioAssets())
            generatedAudioPage = 0
            statusMessage = "Audio saved to Generation History."
        } catch {
            statusMessage = "Could not save audio. Please try again."
        }
    }

    func shareURL(for asset: AudioAsset) -> URL? { managedURL(for: asset) }

    func stopPlayback() {
        player.stop()
        isPlaying = false
    }

    func saveVoice(name: String) {
        guard canSaveVoice, let currentReference else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "Voice name cannot be blank."
            return
        }
        isSavingVoice = true
        defer { isSavingVoice = false }
        let voice = VoiceAsset(name: name,
                               sourceType: currentReference.source, referenceAudio: currentReference.asset)
        do {
            let saved = try audioFileStore.saveVoice(voice)
            savedVoices = SavedVoiceLibrary.voices([saved] + savedVoices, matching: .time)
            savedVoicePage = 0
            mostRecentlySavedVoiceID = saved.id
            selectVoice(.saved(saved.id))
            self.currentReference = nil
            statusMessage = "Voice saved"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setSavedVoiceFilter(_ filter: SavedVoiceFilter) {
        savedVoiceFilter = filter
        savedVoicePage = 0
    }

    func setSavedVoicePage(_ page: Int) {
        savedVoicePage = SavedVoiceLibrary.validPage(page, voiceCount: filteredSavedVoices.count)
    }

    func deleteSavedVoice(id: UUID) {
        do {
            try audioFileStore.deleteVoice(id: id)
            savedVoices = SavedVoiceLibrary.voices(audioFileStore.savedVoices(), matching: .time)
            if currentVoice == .saved(id) {
                selectVoice(savedVoices.first.map { .saved($0.id) } ?? .systemDefault)
                Task { await restoreCurrentVoiceAvailability() }
            }
            savedVoicePage = SavedVoiceLibrary.validPage(savedVoicePage, voiceCount: filteredSavedVoices.count)
            statusMessage = "Voice deleted"
        } catch {
            statusMessage = "Could not delete voice. Please try again."
        }
    }

    func renameSavedVoice(id: UUID, name: String) {
        do {
            let updated = try audioFileStore.renameVoice(id: id, name: name)
            savedVoices = SavedVoiceLibrary.voices(savedVoices.map { $0.id == id ? updated : $0 }, matching: .time)
        } catch { statusMessage = "Could not update voice. Please try again." }
    }

    func setSavedVoiceFavorite(id: UUID, isFavorite: Bool) {
        do {
            let updated = try audioFileStore.setVoiceFavorite(id: id, isFavorite: isFavorite)
            savedVoices = SavedVoiceLibrary.voices(savedVoices.map { $0.id == id ? updated : $0 }, matching: .time)
        } catch { statusMessage = "Could not update voice. Please try again." }
    }

    func setGeneratedAudioPage(_ page: Int) {
        generatedAudioPage = GeneratedAudioLibrary.validPage(page, count: savedGeneratedAudio.count)
    }

    func renameGeneratedAudio(id: UUID, name: String) {
        do {
            let updated = try audioFileStore.updateSavedAudio(id: id, displayName: name)
            refreshGeneratedAudio(updated)
        } catch { statusMessage = "Could not update audio. Please try again." }
    }

    func setGeneratedAudioFavorite(id: UUID, isFavorite: Bool) {
        do {
            let updated = try audioFileStore.updateSavedAudio(id: id, isFavorite: isFavorite)
            refreshGeneratedAudio(updated)
        } catch { statusMessage = "Could not update audio. Please try again." }
    }

    func deleteGeneratedAudio(id: UUID) {
        do {
            try audioFileStore.deleteSavedAudio(id: id)
            savedGeneratedAudio = GeneratedAudioLibrary.assets(audioFileStore.savedAudioAssets())
            if generatedAudio?.id == id { generatedAudio = nil }
            generatedAudioPage = GeneratedAudioLibrary.validPage(generatedAudioPage, count: savedGeneratedAudio.count)
            statusMessage = "Audio deleted."
        } catch VoiceStudioError.assetIsReferenced {
            statusMessage = "This audio is still used by a saved voice."
        } catch { statusMessage = "Could not delete audio. Please try again." }
    }

    private func refreshGeneratedAudio(_ updated: AudioAsset) {
        savedGeneratedAudio = GeneratedAudioLibrary.assets(savedGeneratedAudio.map { $0.id == updated.id ? updated : $0 })
        if generatedAudio?.id == updated.id { generatedAudio = updated }
    }

    func report(_ error: Error) { statusMessage = error.localizedDescription }

    private func setCurrentReference(_ asset: AudioAsset, source: VoiceSourceType) {
        currentReference = CurrentReferenceAudio(asset: asset, source: source)
    }

    private func play(_ asset: AudioAsset) {
        guard !isRecording, !isRequestingPermission else { return }
        do {
            try player.play(asset)
            isPlaying = true
        } catch {
            isPlaying = false
            statusMessage = error.localizedDescription
        }
    }
}
