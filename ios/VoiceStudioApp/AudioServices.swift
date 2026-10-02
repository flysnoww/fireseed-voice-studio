import AVFoundation
import Combine
import Foundation
import KittenTTS
import VoiceStudioCore

enum MicrophonePermissionStatus {
    case undetermined
    case granted
    case denied
}

@MainActor
protocol MicrophonePermissionClient {
    var status: MicrophonePermissionStatus { get }
    func requestAccess() async -> Bool
}

@MainActor
protocol AudioRecording: AnyObject {
    var interruptionHandler: (@MainActor (Result<AudioAsset, Error>) -> Void)? { get set }
    func startRecording() async throws
    func stopRecording() throws -> AudioAsset
}

@MainActor
protocol AudioImporting {
    func importDocument(at externalURL: URL) throws -> AudioAsset
}

@MainActor
struct SystemMicrophonePermissionClient: MicrophonePermissionClient {
    var status: MicrophonePermissionStatus {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .denied
        }
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate, AudioRecording {
    private let fileStore: AudioFileStore
    private let microphonePermissionClient: any MicrophonePermissionClient
    private var recorder: AVAudioRecorder?
    private var isStarting = false
    private var recordingURL: URL?
    private var didFail = false
    private var interruptionObserver: NSObjectProtocol?
    var interruptionHandler: (@MainActor (Result<AudioAsset, Error>) -> Void)?

    init(fileStore: AudioFileStore,
         microphonePermissionClient: (any MicrophonePermissionClient)? = nil) {
        self.fileStore = fileStore
        self.microphonePermissionClient = microphonePermissionClient ?? SystemMicrophonePermissionClient()
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.finishInterruptedRecording() }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func startRecording() async throws {
        guard recorder == nil, !isStarting else { throw VoiceStudioError.recordingFailed }
        isStarting = true
        defer { isStarting = false }
        switch microphonePermissionClient.status {
        case .denied:
            throw VoiceStudioError.microphonePermissionDenied
        case .granted:
            break
        case .undetermined:
            guard await microphonePermissionClient.requestAccess() else {
                throw VoiceStudioError.microphonePermissionDenied
            }
        }

        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let destination = fileStore.recordingDestination()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let candidate = try AVAudioRecorder(url: destination, settings: settings)
            candidate.delegate = self
            guard candidate.prepareToRecord(), candidate.record() else { throw VoiceStudioError.recordingFailed }
            recordingURL = destination
            didFail = false
            recorder = candidate
        } catch {
            try? fileStore.discardRecording(at: destination)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stopRecording() throws -> AudioAsset {
        guard let recorder, let recordingURL else { throw VoiceStudioError.recordingFailed }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.recordingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard !didFail else {
            try? fileStore.discardRecording(at: recordingURL)
            throw VoiceStudioError.recordingFailed
        }
        do {
            return try fileStore.registerRecording(at: recordingURL, duration: duration)
        } catch {
            try? fileStore.discardRecording(at: recordingURL)
            throw error
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, self.recorder.map(ObjectIdentifier.init) == identity else { return }
            self.didFail = true
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, self.recorder.map(ObjectIdentifier.init) == identity else { return }
            if !flag { self.didFail = true; self.finishInterruptedRecording() }
        }
    }

    private func finishInterruptedRecording() {
        guard recorder != nil else { return }
        do {
            interruptionHandler?(.success(try stopRecording()))
        } catch {
            interruptionHandler?(.failure(error))
        }
    }
}

@MainActor
final class AudioImporter: AudioImporting {
    private let fileStore: AudioFileStore
    init(fileStore: AudioFileStore) { self.fileStore = fileStore }

    func importDocument(at externalURL: URL) throws -> AudioAsset {
        let didStartScope = externalURL.startAccessingSecurityScopedResource()
        defer { if didStartScope { externalURL.stopAccessingSecurityScopedResource() } }
        let player = try AVAudioPlayer(contentsOf: externalURL)
        guard player.duration.isFinite, player.duration > 0 else { throw VoiceStudioError.invalidAudioFile }
        return try fileStore.importAudio(from: externalURL, duration: player.duration)
    }
}

@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    var stateHandler: (@MainActor (Bool) -> Void)?
    private let fileStore: AudioFileStore
    private var player: AVAudioPlayer?
    private var playbackLease: AudioFileLease?
    private(set) var playingAssetID: UUID?
    private var interruptionObserver: NSObjectProtocol?

    init(fileStore: AudioFileStore) {
        self.fileStore = fileStore
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    func play(_ asset: AudioAsset) throws {
        stop()
        let lease = try AudioFileLease(source: fileStore.managedURL(for: asset))
        let url = lease.url
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            guard next.duration.isFinite, next.duration > 0, next.prepareToPlay() else {
                throw VoiceStudioError.invalidAudioFile
            }
            player = next
            playbackLease = lease
            playingAssetID = asset.id
            guard next.play() else {
                player = nil
                playbackLease = nil
                playingAssetID = nil
                throw VoiceStudioError.invalidAudioFile
            }
            isPlaying = true
            stateHandler?(true)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playbackLease = nil
        playingAssetID = nil
        isPlaying = false
        stateHandler?(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }
            self.stop()
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }

}

struct SpeechProviderAssembly {
    let providers: [SpeechProviderID: any SpeechProvider]
    let localPackProvider: any InstallableSpeechProvider

    static func production(diagnostics: VoiceStudioDiagnostics) -> SpeechProviderAssembly {
        let local = QwenRendererAdapter(diagnostics: diagnostics)
        let system = AppleSystemSpeechProvider()
        let tiny = KittenLocalSpeechProvider(diagnostics: diagnostics)
        return SpeechProviderAssembly(providers: [.system: system, .tinyLocal: tiny, .local: local],
                                      localPackProvider: local)
    }
}

/// A fixed English local voice; its model cache is managed by the upstream SDK in Application Support.
actor KittenLocalSpeechProvider: SpeechProvider {
    nonisolated static let installedPackURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RendererPacks/TinyLocal", isDirectory: true)
    nonisolated let id: SpeechProviderID = .tinyLocal
    nonisolated let capabilities = CapabilityProfile(
        support: [.speechGeneration: .supported, .voiceCloning: .unsupported,
                  .languageSelection: .supported, .accentSelection: .unsupported,
                  .speed: .supported, .pitch: .supported],
        languages: ["en"])
    private let diagnostics: VoiceStudioDiagnostics
    private var renderer: KittenTTS?
    private var runtimeInUse = false

    private static var config: KittenTTSConfig {
        KittenTTSConfig(model: .nanoInt8, defaultVoice: .bella,
                        storageDirectory: installedPackURL, ortNumThreads: 2)
    }

    init(diagnostics: VoiceStudioDiagnostics) { self.diagnostics = diagnostics }

    func generate(_ request: VoiceRequest, voice: VoiceAsset?, referenceAudioURL: URL?) async -> SpeechResult {
        guard case .tinyLocal = request.voice,
              request.renderMode == .generate,
              capabilities.supports(language: request.language) else {
            return .unsupported(.speechGeneration)
        }
        guard !runtimeInUse, !Task.isCancelled else { return .failure("Local voice is busy or cancelled.") }
        runtimeInUse = true
        defer { runtimeInUse = false; renderer = nil }
        do {
            guard isInstalled() else { return .failure("Install the optional local voice first.") }
            if renderer == nil {
                let loadStarted = ProcessInfo.processInfo.systemUptime
                await diagnostics.update {
                    $0.provider = "Tiny local"; $0.rendererID = "KittenTTS-Nano-int8"
                    $0.backend = "ONNX Runtime · CPU"; $0.runtime = "loading"
                    $0.language = request.language ?? "en"; $0.voice = "built-in"
                }
                renderer = try await KittenTTS(Self.config)
                await diagnostics.update {
                    $0.runtime = "loaded"
                    $0.rendererLoadDurationMilliseconds = max(0, Int((ProcessInfo.processInfo.systemUptime - loadStarted) * 1000))
                }
            }
            guard let renderer else { return .failure("Local voice is not available right now.") }
            let generationStarted = ProcessInfo.processInfo.systemUptime
            try Task.checkCancellation()
            let result = try await renderer.generate(request.text, speed: 1)
            try Task.checkCancellation()
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("tiny-local-\(UUID().uuidString).wav")
            try result.wavData().write(to: output, options: .atomic)
            await diagnostics.update {
                $0.provider = "Tiny local"
                $0.rendererID = "KittenTTS-Nano-int8"
                $0.backend = "ONNX Runtime · CPU"
                $0.runtime = "loaded"
                $0.rendererGenerationDurationMilliseconds = max(0, Int((ProcessInfo.processInfo.systemUptime - generationStarted) * 1000))
                $0.language = request.language ?? "en"
                $0.voice = "built-in"
            }
            return .renderedFile(output, duration: result.duration, approximation: nil)
        } catch {
            await diagnostics.update {
                $0.provider = "Tiny local"
                $0.rendererID = "KittenTTS-Nano-int8"
                $0.backend = "ONNX Runtime · CPU"
                $0.runtime = "failed"
            }
            return .failure("Local speech could not be generated. Please try again.")
        }
    }

    func isInstalled() -> Bool { KittenTTS.isModelCached(for: Self.config) }
    func install() async throws {
        guard !runtimeInUse else { throw VoiceStudioError.invalidAudioFile }
        runtimeInUse = true
        defer { runtimeInUse = false; renderer = nil }
        renderer = try await KittenTTS(Self.config)
    }
    func unload() { renderer = nil }

    func deleteInstalledPack() throws {
        guard !runtimeInUse else { throw VoiceStudioError.invalidAudioFile }
        renderer = nil
        if FileManager.default.fileExists(atPath: Self.installedPackURL.path) {
            try FileManager.default.removeItem(at: Self.installedPackURL)
        }
    }
}

protocol VoicePreparingSpeechProvider: SpeechProvider {
    func prepareVoice(_ voice: VoiceAsset, referenceAudioURL: URL) async throws
}

protocol VoiceConverterProvider: Sendable {
    func timings() async -> VoiceConverterTimings?
    var capabilities: CapabilityProfile { get }
    func validateModels(packDirectory: URL, cacheDirectory: URL) async throws
    func prepareReference(referenceURL: URL, voiceID: UUID, referenceAudioID: UUID,
                         packDirectory: URL, cacheDirectory: URL) async throws
    func convert(sourceURL: URL, targetReferenceURL: URL, targetVoiceID: UUID,
                 targetReferenceID: UUID, packDirectory: URL, cacheDirectory: URL) async throws -> URL
}

struct VoiceConverterTimings: Sendable {
    var embeddingCacheHit = false
    var loadMilliseconds = 0
    var embeddingMilliseconds = 0
    var conversionMilliseconds = 0
}
extension VoiceConverterProvider { func timings() async -> VoiceConverterTimings? { nil } }

protocol SpeechRuntimeManaging: SpeechProvider {
    func unloadRuntime() async
}

enum SystemVoiceCatalog {
    static let languageRanking = ["zh", "es", "hi", "ar", "fr", "pt", "bn", "ru", "ja", "de", "ko", "it", "tr", "vi", "id", "th", "nl", "pl", "uk", "sv"]
    static func baseLanguage(_ tag: String) -> String { tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? tag }
    static func groupByBaseLanguage(_ voices: [SystemVoiceDescriptor]) -> [String: [SystemVoiceDescriptor]] {
        Dictionary(grouping: Array(Dictionary(voices.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first }).values)) { baseLanguage($0.language) }
    }
    static func rankLanguages(_ languages: [String], systemLanguage: String, locale: Locale) -> [String] {
        let priority = [baseLanguage(systemLanguage), "en"] + languageRanking
        return Array(Set(languages)).sorted { a, b in
            let ar = priority.firstIndex(of: a) ?? Int.max
            let br = priority.firstIndex(of: b) ?? Int.max
            if ar != br { return ar < br }
            let an = locale.localizedString(forLanguageCode: a) ?? a
            let bn = locale.localizedString(forLanguageCode: b) ?? b
            if an != bn { return an.localizedStandardCompare(bn) == .orderedAscending }
            return a < b
        }
    }
    static func rankVoices(_ voices: [SystemVoiceDescriptor], locale: Locale) -> [SystemVoiceDescriptor] {
        voices.sorted {
            if $0.isPersonal != $1.isPersonal { return $0.isPersonal }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            let a = $0.language == locale.identifier.replacingOccurrences(of: "_", with: "-")
            let b = $1.language == locale.identifier.replacingOccurrences(of: "_", with: "-")
            if a != b { return a }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.identifier < $1.identifier
        }
    }
    static func voices(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        voices.sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
    }

    static func personalVoices(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        voices.filter { $0.voiceTraits.contains(.isPersonalVoice) }
    }

    static func nonPersonalVoices(_ voices: [AVSpeechSynthesisVoice]) -> [AVSpeechSynthesisVoice] {
        voices.filter { !$0.voiceTraits.contains(.isPersonalVoice) }
    }
}

struct SystemVoiceDescriptor: Identifiable, Equatable, Sendable {
    let identifier: String
    let name: String
    let language: String
    let quality: Int
    let gender: Int
    let isPersonal: Bool
    var id: String { identifier }
    init(identifier: String, name: String, language: String, quality: Int = 1, gender: Int = 0, isPersonal: Bool = false) {
        self.identifier = identifier; self.name = name; self.language = language
        self.quality = quality; self.gender = gender; self.isPersonal = isPersonal
    }
    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(identifier: voice.identifier, name: voice.name, language: voice.language,
                  quality: voice.quality.rawValue, gender: voice.gender.rawValue,
                  isPersonal: voice.voiceTraits.contains(.isPersonalVoice))
    }
}

enum SystemVoiceProbeResult: Equatable {
    case testing, usable, failed
}

@MainActor
final class SystemVoiceAvailabilityCache: ObservableObject {
    @Published private(set) var results: [String: SystemVoiceProbeResult] = [:]
    private(set) var diagnostics: [String: String] = [:]
    private var revision = 0
    private var pending: [String: Task<Bool, Never>] = [:]
    private var pendingIDs: [String: UUID] = [:]
    var onInvalidation: (() -> Void)?
    private var observer: NSObjectProtocol?
    private let probe: @Sendable (SystemVoiceDescriptor) async -> Bool
    init(probe: @escaping @Sendable (SystemVoiceDescriptor) async -> Bool = { voice in await SystemVoiceProbeSession.probe(voice) }) {
        self.probe = probe
        observer = NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.invalidate() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func invalidate() {
        revision += 1
        pending.values.forEach { $0.cancel() }; pending.removeAll(); pendingIDs.removeAll()
        results.removeAll(); diagnostics.removeAll(); onInvalidation?()
    }
    func usable(_ voices: [SystemVoiceDescriptor]) -> [SystemVoiceDescriptor] { voices.filter { results[$0.identifier] == .usable } }
    func test(_ voices: [SystemVoiceDescriptor]) async {
        let activeRevision = revision
        for voice in voices {
            guard !Task.isCancelled, revision == activeRevision else { return }
            if let result = results[voice.identifier], result != .testing { continue }
            let task: Task<Bool, Never>
            if let existing = pending[voice.identifier] { task = existing }
            else {
                results[voice.identifier] = .testing
                let probe = self.probe
                task = Task { await probe(voice) }
                pending[voice.identifier] = task
                pendingIDs[voice.identifier] = UUID()
            }
            let pendingID = pendingIDs[voice.identifier]
            let usable = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            guard revision == activeRevision, pendingIDs[voice.identifier] == pendingID else { return }
            pendingIDs.removeValue(forKey: voice.identifier)
            pending.removeValue(forKey: voice.identifier)
            if Task.isCancelled || task.isCancelled { results.removeValue(forKey: voice.identifier); return }
            results[voice.identifier] = usable ? .usable : .failed
            if !usable { diagnostics[voice.identifier] = "synthesisProbe · \(voice.identifier) · \(voice.language) · quality=\(voice.quality) · no valid PCM" }
        }
    }
}

/// All AVSpeechSynthesizer instances and cancellation are owned by one MainActor queue.
/// Buffer callbacks only touch the lock-protected writer; they never mutate UI state.
@MainActor
final class NativeSpeechEngine {
    static let shared = NativeSpeechEngine()
    private struct Job {
        let id: UUID
        let text: String
        let voice: AVSpeechSynthesisVoice
        let timeout: TimeInterval
        let continuation: CheckedContinuation<SpeechResult, Never>
    }
    private var queue: [Job] = []
    private var active: Job?
    private var synthesizer: AVSpeechSynthesizer?
    private var writer: SpeechBufferWriter?
    private var timeoutTask: Task<Void, Never>?

    func render(text: String, identifier: String? = nil, language: String? = nil,
                timeout: TimeInterval = 45) async -> SpeechResult {
        guard !Task.isCancelled else { return .failure("Speech cancelled.") }
        let voice = identifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? (identifier == nil ? language.flatMap(AVSpeechSynthesisVoice.init(language:)) : nil)
        guard let voice else { return .unsupported(.speechGeneration) }
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                queue.append(Job(id: id, text: text, voice: voice, timeout: timeout, continuation: continuation))
                startNext()
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel(id) } })
    }
    private func startNext() {
        guard active == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        active = job
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-speech-\(job.id).wav")
        let sink = SpeechBufferWriter(destination: url) { [weak self] result in
            Task { @MainActor in self?.complete(job.id, result: result) }
        }
        writer = sink
        let speech = AVSpeechSynthesizer()
        synthesizer = speech
        let utterance = AVSpeechUtterance(string: job.text)
        utterance.voice = job.voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speech.write(utterance, toBufferCallback: sink.callback)
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(job.timeout * 1_000_000_000)) }
            catch { return }
            self?.writer?.finish(.failure("System speech timed out. Please select another voice."))
        }
    }
    private func cancel(_ id: UUID) {
        if active?.id == id { writer?.finish(.failure("Speech cancelled.")); return }
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).continuation.resume(returning: .failure("Speech cancelled."))
    }
    private func complete(_ id: UUID, result: SpeechResult) {
        guard let job = active, job.id == id else { return }
        timeoutTask?.cancel(); timeoutTask = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil; writer = nil; active = nil
        job.continuation.resume(returning: result)
        startNext()
    }
}

private enum SystemVoiceProbeSession {
    static func phrase(_ language: String) -> String {
        ["en": "Hello.", "zh": "你好。", "es": "Hola.", "hi": "नमस्ते।", "ar": "مرحبا.", "fr": "Bonjour.", "pt": "Olá.", "ja": "こんにちは。", "ko": "안녕하세요.", "de": "Hallo.", "ru": "Привет.", "it": "Ciao.", "bn": "হ্যালো।", "tr": "Merhaba.", "vi": "Xin chào.", "id": "Halo.", "th": "สวัสดี", "nl": "Hallo.", "pl": "Cześć.", "uk": "Привіт.", "sv": "Hej."][language] ?? "Hello."
    }
    static func probe(_ voice: SystemVoiceDescriptor) async -> Bool {
        let result = await NativeSpeechEngine.shared.render(text: phrase(SystemVoiceCatalog.baseLanguage(voice.language)),
                                                           identifier: voice.identifier, timeout: 8)
        guard case .renderedFile(let url, let duration, _) = result else { return false }
        defer { try? FileManager.default.removeItem(at: url) }
        return !Task.isCancelled && duration.isFinite && duration > 0
    }
}

actor AppleSystemSpeechProvider: SpeechProvider {
    nonisolated let id: SpeechProviderID = .system
    nonisolated private let catalogOverride: [SystemVoiceDescriptor]?
    nonisolated var capabilities: CapabilityProfile {
        let tags = Set((catalogOverride ?? AVSpeechSynthesisVoice.speechVoices().map(SystemVoiceDescriptor.init)).map(\.language))
        let groups = Dictionary(grouping: tags) { SystemVoiceCatalog.baseLanguage($0) }
        return CapabilityProfile(
            support: [.speechGeneration: .supported, .languageSelection: .supported,
                      .accentSelection: .supported, .speed: .supported, .pitch: .supported],
            shaping: [:], languages: groups.keys.sorted(),
            accentsByLanguage: groups.mapValues { $0.sorted() })
    }

    init(voices: [AVSpeechSynthesisVoice]? = nil) { catalogOverride = voices?.map(SystemVoiceDescriptor.init) }

    func generate(_ request: VoiceRequest, voice: VoiceAsset?, referenceAudioURL: URL?) async -> SpeechResult {
        guard request.renderMode == .generate else { return .unsupported(.speechGeneration) }
        let speechVoice: AVSpeechSynthesisVoice
        switch request.voice {
        case .systemDefault:
            let tag = request.accent ?? request.language
            guard let tag, let resolved = AVSpeechSynthesisVoice(language: tag) else {
                return .unsupported(.accentSelection)
            }
            speechVoice = resolved
        case .systemVoice(let identifier):
            guard let resolved = AVSpeechSynthesisVoice(identifier: identifier) else { return .unsupported(.speechGeneration) }
            speechVoice = resolved
        default:
            return .unsupported(.voiceCloning)
        }
        return await NativeSpeechEngine.shared.render(text: request.text, identifier: speechVoice.identifier)
    }
}

private final class SpeechBufferWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let completion: @Sendable (SpeechResult) -> Void
    private var file: AVAudioFile?
    private var frameCount: AVAudioFramePosition = 0
    private var finished = false

    init(destination: URL, completion: @escaping @Sendable (SpeechResult) -> Void) {
        self.destination = destination
        self.completion = completion
    }
    var callback: AVSpeechSynthesizer.BufferCallback { { [self] buffer in append(buffer) } }

    func append(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            finish(.failure("System speech could not produce playable audio."))
            return
        }
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if pcm.frameLength == 0 {
            let result: SpeechResult
            if frameCount > 0, pcm.format.sampleRate > 0 {
                result = .renderedFile(destination,
                                       duration: Double(frameCount) / pcm.format.sampleRate,
                                       approximation: nil)
            } else {
                result = .failure("System speech returned no audio.")
            }
            file = nil
            finished = true
            lock.unlock()
            completion(result)
            return
        }
        do {
            guard pcm.format.sampleRate.isFinite, pcm.format.sampleRate > 0, pcm.format.channelCount > 0 else { throw VoiceStudioError.invalidAudioFile }
            if file == nil { file = try AVAudioFile(forWriting: destination, settings: pcm.format.settings) }
            try file?.write(from: pcm)
            frameCount += AVAudioFramePosition(pcm.frameLength)
            lock.unlock()
        } catch {
            finished = true
            file = nil
            try? FileManager.default.removeItem(at: destination)
            lock.unlock()
            completion(.failure("System speech audio could not be written."))
        }
    }

    func finish(_ result: SpeechResult) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        file = nil
        try? FileManager.default.removeItem(at: destination)
        lock.unlock()
        completion(result)
    }
}

struct AudioTimePitchProcessor {
    func processAsync(_ sourceURL: URL, speed: Double, pitch: Double,
                      shaping: VoiceShaping = VoiceShaping()) async throws -> URL {
        let task = Task.detached(priority: .userInitiated) { try self.process(sourceURL, speed: speed, pitch: pitch, shaping: shaping) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    static func accepts(speed: Double, pitch: Double, shaping: VoiceShaping = VoiceShaping()) -> Bool {
        speed.isFinite && (0.5...2).contains(speed) && pitch.isFinite && (-1200...1200).contains(pitch) &&
            shaping.values.values.allSatisfy { $0.isFinite && (-1...1).contains($0) } &&
            shaping.values.keys.allSatisfy { [.brightness, .clarity, .softness].contains($0) }
    }

    func process(_ sourceURL: URL, speed: Double, pitch: Double,
                 shaping: VoiceShaping = VoiceShaping()) throws -> URL {
        guard Self.accepts(speed: speed, pitch: pitch, shaping: shaping) else {
            throw VoiceStudioError.invalidAudioFile
        }
        guard abs(speed - 1) > 0.001 || abs(pitch) > 0.5 || !shaping.values.isEmpty else { return sourceURL }
        let input = try AVAudioFile(forReading: sourceURL)
        let format = input.processingFormat
        guard input.length > 0, format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0, format.channelCount <= 2 else { throw VoiceStudioError.invalidAudioFile }
        try Task.checkCancellation()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let equalizer = AVAudioUnitEQ(numberOfBands: 2)
        timePitch.rate = Float(speed)
        timePitch.pitch = Float(pitch)
        let brightness = shaping.values[.brightness, default: 0]
        let softness = shaping.values[.softness, default: 0]
        let clarity = shaping.values[.clarity, default: 0]
        let highShelf = equalizer.bands[0]
        highShelf.filterType = .highShelf
        highShelf.frequency = 4_000
        highShelf.bandwidth = 0.7
        highShelf.gain = Float((brightness - softness) * 6)
        highShelf.bypass = abs(brightness - softness) < 0.01
        let presence = equalizer.bands[1]
        presence.filterType = .parametric
        presence.frequency = 2_800
        presence.bandwidth = 0.8
        presence.gain = Float(clarity * 4)
        presence.bypass = abs(clarity) < 0.01
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(equalizer)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shaped-speech-\(UUID().uuidString).wav")
        do {
            var outputSettings = input.fileFormat.settings
            outputSettings[AVLinearPCMIsFloatKey] = true
            outputSettings[AVLinearPCMBitDepthKey] = 32
            outputSettings[AVLinearPCMIsBigEndianKey] = false
            outputSettings[AVLinearPCMIsNonInterleaved] = false
            let output = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
            guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw VoiceStudioError.invalidAudioFile }
            var renderedFrames: AVAudioFramePosition = 0
            let targetFrames = AVAudioFramePosition(ceil(Double(input.length) / speed))
            engine.prepare()
            try engine.start()
            player.scheduleFile(input, at: nil)
            player.play()
            var attempts = 0
            while engine.manualRenderingSampleTime < targetFrames && attempts < 100_000 {
                try Task.checkCancellation()
                attempts += 1
                let remaining = targetFrames - engine.manualRenderingSampleTime
                let framesToRender = AVAudioFrameCount(min(remaining, AVAudioFramePosition(renderBuffer.frameCapacity)))
                switch try engine.renderOffline(framesToRender, to: renderBuffer) {
                case .success:
                    if renderBuffer.frameLength > 0 {
                        try output.write(from: renderBuffer)
                        renderedFrames += AVAudioFramePosition(renderBuffer.frameLength)
                    }
                case .insufficientDataFromInputNode:
                    continue
                case .cannotDoInCurrentContext:
                    continue
                case .error:
                    throw VoiceStudioError.invalidAudioFile
                @unknown default:
                    throw VoiceStudioError.invalidAudioFile
                }
            }
            engine.stop()
            guard engine.manualRenderingSampleTime >= targetFrames, renderedFrames > 0 else {
                throw VoiceStudioError.invalidAudioFile
            }
            return outputURL
        } catch {
            engine.stop()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}


struct PerformanceTransferCapabilities: Sendable {
    let sameContentConversion: Bool
    let newTextStyleTransfer: Bool
}
protocol PerformanceTransferProvider: Sendable {
    var performanceCapabilities: PerformanceTransferCapabilities { get }
    func transfer(referenceAudio: URL, targetVoice: VoiceAsset, targetReference: URL,
                  optionalText: String, language: String, voiceProfile: VoiceProfile) async throws -> URL
}
/// Same-content audio conversion only. A future provider may implement new-text transfer
/// here; any cloud implementation must require explicit consent before receiving audio.
struct LocalPerformanceTransfer: PerformanceTransferProvider {
    let converter: any VoiceConverterProvider
    let packDirectory: URL
    let cacheDirectory: URL
    let performanceCapabilities = PerformanceTransferCapabilities(sameContentConversion: true, newTextStyleTransfer: false)
    func transfer(referenceAudio: URL, targetVoice: VoiceAsset, targetReference: URL,
                  optionalText: String, language: String, voiceProfile: VoiceProfile) async throws -> URL {
        guard optionalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PerformanceTransferError.newTextUnsupported
        }
        try Task.checkCancellation()
        return try await converter.convert(sourceURL: referenceAudio, targetReferenceURL: targetReference,
            targetVoiceID: targetVoice.id, targetReferenceID: targetVoice.referenceAudio.id,
            packDirectory: packDirectory, cacheDirectory: cacheDirectory)
    }
}
enum PerformanceTransferError: Error { case newTextUnsupported }
