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

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        didFail = true
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag { didFail = true }
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
        let url = try fileStore.managedURL(for: asset)
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
            guard next.play() else {
                player = nil
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
        isPlaying = false
        stateHandler?(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stateHandler?(false)
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        do {
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
            let result = try await renderer.generate(request.text, speed: 1)
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

    func deleteInstalledPack() throws {
        renderer = nil
        if FileManager.default.fileExists(atPath: Self.installedPackURL.path) {
            try FileManager.default.removeItem(at: Self.installedPackURL)
        }
    }
}

protocol VoicePreparingSpeechProvider: SpeechProvider {
    func prepareVoice(_ voice: VoiceAsset, referenceAudioURL: URL) async throws
}

protocol SpeechRuntimeManaging: SpeechProvider {
    func unloadRuntime() async
}

actor AppleSystemSpeechProvider: SpeechProvider {
    nonisolated let id: SpeechProviderID = .system
    nonisolated let capabilities: CapabilityProfile
    private let availableVoiceTags: Set<String>

    init(voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()) {
        let tags = Set(voices.map(\.language))
        let groups = Dictionary(grouping: tags) { $0.split(separator: "-").first.map(String.init) ?? $0 }
        availableVoiceTags = tags
        capabilities = CapabilityProfile(
            support: [.speechGeneration: .supported, .languageSelection: .supported,
                      .accentSelection: .supported],
            languages: groups.keys.sorted(),
            accentsByLanguage: groups.mapValues { $0.sorted() })
    }

    func generate(_ request: VoiceRequest, voice: VoiceAsset?, referenceAudioURL: URL?) async -> SpeechResult {
        guard case .systemDefault = request.voice else { return .unsupported(.voiceCloning) }
        guard request.renderMode == .generate else { return .unsupported(.speechGeneration) }
        let tag = request.accent ?? request.language
        guard let tag, availableVoiceTags.contains(tag), let speechVoice = AVSpeechSynthesisVoice(language: tag) else {
            return .unsupported(.accentSelection)
        }
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = speechVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let synthesizer = AVSpeechSynthesizer()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-speech-\(UUID().uuidString).wav")
        return await withCheckedContinuation { continuation in
            let writer = SpeechBufferWriter(destination: outputURL, continuation: continuation)
            synthesizer.write(utterance) { buffer in writer.append(buffer) }
        }
    }
}

private final class SpeechBufferWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let continuation: CheckedContinuation<SpeechResult, Never>
    private var file: AVAudioFile?
    private var frameCount: AVAudioFramePosition = 0
    private var finished = false

    init(destination: URL, continuation: CheckedContinuation<SpeechResult, Never>) {
        self.destination = destination
        self.continuation = continuation
    }

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
            continuation.resume(returning: result)
            return
        }
        do {
            if file == nil { file = try AVAudioFile(forWriting: destination, settings: pcm.format.settings) }
            try file?.write(from: pcm)
            frameCount += AVAudioFramePosition(pcm.frameLength)
            lock.unlock()
        } catch {
            finished = true
            try? FileManager.default.removeItem(at: destination)
            lock.unlock()
            continuation.resume(returning: .failure("System speech audio could not be written."))
        }
    }

    private func finish(_ result: SpeechResult) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        try? FileManager.default.removeItem(at: destination)
        lock.unlock()
        continuation.resume(returning: result)
    }
}

struct AudioTimePitchProcessor {
    func process(_ sourceURL: URL, speed: Double, pitch: Double) throws -> URL {
        guard speed.isFinite, (0.5...2).contains(speed), pitch.isFinite, (-2400...2400).contains(pitch) else {
            throw VoiceStudioError.invalidAudioFile
        }
        guard abs(speed - 1) > 0.001 || abs(pitch) > 0.5 else { return sourceURL }
        let input = try AVAudioFile(forReading: sourceURL)
        let format = input.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(speed)
        timePitch.pitch = Float(pitch)
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shaped-speech-\(UUID().uuidString).wav")
        do {
            let output = try AVAudioFile(forWriting: outputURL, settings: input.fileFormat.settings)
            let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            let expectedFrames = AVAudioFramePosition(ceil(Double(input.length) / speed))
            let outputFrameLimit = expectedFrames + AVAudioFramePosition(format.sampleRate * 0.25)
            var renderedFrames: AVAudioFramePosition = 0
            engine.prepare()
            try engine.start()
            player.scheduleFile(input, at: nil, completionCallbackType: .dataRendered) { _ in }
            player.play()
            var attempts = 0
            while renderedFrames < outputFrameLimit, attempts < 10_000 {
                attempts += 1
                let framesToRender = AVAudioFrameCount(min(4096, outputFrameLimit - renderedFrames))
                switch try engine.renderOffline(framesToRender, to: renderBuffer) {
                case .success:
                    if renderBuffer.frameLength > 0 {
                        try output.write(from: renderBuffer)
                        renderedFrames += AVAudioFramePosition(renderBuffer.frameLength)
                    }
                case .insufficientDataFromInputNode:
                    if renderedFrames >= expectedFrames {
                        engine.stop()
                        return outputURL
                    }
                    continue
                case .cannotDoInCurrentContext:
                    continue
                @unknown default:
                    throw VoiceStudioError.invalidAudioFile
                }
            }
            if renderedFrames > 0 {
                engine.stop()
                return outputURL
            }
            throw VoiceStudioError.invalidAudioFile
        } catch {
            engine.stop()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}
