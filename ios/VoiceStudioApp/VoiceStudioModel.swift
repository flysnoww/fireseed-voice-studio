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
    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var microphonePermissionDenied = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isSavingVoice = false
    @Published private(set) var isInstallingLocalSpeech = false
    @Published private(set) var isGeneratingSpeech = false
    @Published private(set) var isLocalSpeechReady = false
    @Published private(set) var isTinyLocalModelReady = false
    @Published private(set) var isDeletingTinyLocalModel = false
    @Published private(set) var voicePreparationState: VoicePreparationState = .none
    @Published private(set) var preparedVoiceID: UUID?
    @Published private(set) var preparationVoiceID: UUID?
    @Published private(set) var generatedAudio: AudioAsset?
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

    private let recorder: any AudioRecording
    private let importer: any AudioImporting
    private let player: AudioPlayer

    init(rootDirectory: URL? = nil,
         microphonePermissionClient: (any MicrophonePermissionClient)? = nil,
         audioRecorder: (any AudioRecording)? = nil,
         audioImporter: (any AudioImporting)? = nil,
         providerAssembly: SpeechProviderAssembly? = nil,
         diagnostics suppliedDiagnostics: VoiceStudioDiagnostics? = nil) throws {
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
        self.audioLifecycle = AudioLifecycle(fileStore: fileStore)
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

    func capabilities(for selection: VoiceSelection) -> CapabilityProfile {
        let providerID: SpeechProviderID
        switch selection {
        case .systemDefault: providerID = .system
        case .tinyLocal: providerID = .tinyLocal
        case .saved: providerID = .local
        }
        guard let provider = providers[providerID] else { return CapabilityProfile() }
        var support = provider.capabilities.support
        support[.speed] = .supported
        support[.pitch] = .supported
        return CapabilityProfile(support: support, shaping: provider.capabilities.shaping,
                                 expressions: provider.capabilities.expressions,
                                 languages: provider.capabilities.languages,
                                 accentsByLanguage: provider.capabilities.accentsByLanguage)
    }

    func availableLanguages(for selection: VoiceSelection) -> [String] {
        capabilities(for: selection).languages
    }

    func availableAccents(for selection: VoiceSelection, language: String?) -> [String] {
        capabilities(for: selection).accents(for: language)
    }

    func canGenerate(text: String, voice: VoiceSelection, language: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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
        guard selection.savedVoiceID == nil, isLocalSpeechReady,
              let runtimeManager = localPackProvider as? any SpeechRuntimeManaging else { return }
        isLocalSpeechReady = false
        preparedVoiceID = nil
        preparationVoiceID = nil
        voicePreparationState = .none
        diagnostics.update { $0.runtime = "not loaded"; $0.reference = "none" }
        await runtimeManager.unloadRuntime()
    }

    func updateDiagnosticContext(voice: VoiceSelection, language: String, accent: String?,
                                 hasText: Bool, hasCurrentReference: Bool) {
        diagnostics.update {
            switch voice {
            case .systemDefault:
                $0.provider = "System"; $0.rendererID = nil; $0.backend = "System"; $0.voice = "system"
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

    func generateSpeech(text: String, voice selection: VoiceSelection, language: String,
                        accent: String?, shaping: VoiceShaping = VoiceShaping(),
                        expression: VoiceExpression? = nil, speed: Double = 1,
                        pitch: Double = 0) async {
        guard !isGeneratingSpeech else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            diagnostics.update { $0.request = "invalid"; $0.generation = "failed" }
            return
        }
        if let voiceID = selection.savedVoiceID, preparedVoiceID != voiceID {
            statusMessage = "Confirm this voice before generating."
            diagnostics.update { $0.request = "invalid"; $0.generation = "idle" }
            return
        }
        guard canGenerate(text: text, voice: selection, language: language) else { return }
        let effectiveCapabilities = capabilities(for: selection)
        guard shaping.values.keys.allSatisfy({ effectiveCapabilities.shaping[$0] != nil && effectiveCapabilities.shaping[$0] != .unsupported }),
              expression.map({ effectiveCapabilities.expressions[$0] != nil && effectiveCapabilities.expressions[$0] != .unsupported }) ?? true,
              effectiveCapabilities.status(for: .speed) == .supported,
              effectiveCapabilities.status(for: .pitch) == .supported else {
            statusMessage = "Some selected voice controls are not available."
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
                let shapedURL = try timePitchProcessor.process(rawURL, speed: speed, pitch: pitch)
                diagnostics.finish(.dsp, startedAt: dspStarted)
                activeStage = nil
                defer { if shapedURL != rawURL { try? FileManager.default.removeItem(at: shapedURL) } }
                let outputFile = try AVAudioFile(forReading: shapedURL)
                let duration = Double(outputFile.length) / outputFile.processingFormat.sampleRate
                let outputStarted = ProcessInfo.processInfo.systemUptime
                activeStage = .output
                activeStageStartedAt = outputStarted
                diagnostics.start(.output)
                let asset = try audioFileStore.registerGeneratedAudio(from: shapedURL, duration: duration,
                                                                     sourceVoiceID: voice?.id, text: text)
                try audioLifecycle.cache(asset, as: .generated)
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

    func saveGeneratedAudio() {
        guard let generatedAudio, generatedAudio.persistenceState == .temporary else { return }
        do {
            self.generatedAudio = try audioLifecycle.save(id: generatedAudio.id, from: .generated)
            statusMessage = "Audio saved."
        } catch {
            statusMessage = "Could not save audio. Please try again."
        }
    }

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
            savedVoicePage = SavedVoiceLibrary.validPage(savedVoicePage, voiceCount: filteredSavedVoices.count)
            statusMessage = "Voice deleted"
        } catch {
            statusMessage = "Could not delete voice. Please try again."
        }
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
