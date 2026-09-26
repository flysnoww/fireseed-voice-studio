import AVFoundation
import Combine
import Foundation
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
