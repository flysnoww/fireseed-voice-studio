import Combine
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
    static func canSave(hasCurrentReference: Bool, isRecording: Bool, isRequestingPermission: Bool) -> Bool {
        hasCurrentReference && !isRecording && !isRequestingPermission
    }
}

@MainActor
final class VoiceStudioModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var microphonePermissionDenied = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentReference: CurrentReferenceAudio?
    @Published private(set) var savedVoices: [VoiceAsset] = []
    @Published var statusMessage = "Record or import a reference audio file to create a voice."

    var isReferenceReady: Bool { currentReference != nil }
    var canSaveVoice: Bool {
        VoiceAvailabilityPolicy.canSave(hasCurrentReference: isReferenceReady,
                                        isRecording: isRecording,
                                        isRequestingPermission: isRequestingPermission)
    }

    private let audioFileStore: AudioFileStore

    private let recorder: any AudioRecording
    private let importer: any AudioImporting
    private let player: AudioPlayer

    init(rootDirectory: URL? = nil,
         microphonePermissionClient: (any MicrophonePermissionClient)? = nil,
         audioRecorder: (any AudioRecording)? = nil,
         audioImporter: (any AudioImporting)? = nil) throws {
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

        let activeRecorder = audioRecorder ?? AudioRecorder(fileStore: fileStore,
                                                            microphonePermissionClient: microphonePermissionClient)
        self.recorder = activeRecorder
        self.importer = audioImporter ?? AudioImporter(fileStore: fileStore)
        self.player = AudioPlayer(fileStore: fileStore)
        self.savedVoices = fileStore.savedVoices()
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

    func stopPlayback() {
        player.stop()
        isPlaying = false
    }

    func saveVoice(name: String) {
        guard canSaveVoice, let currentReference else { return }
        let voice = VoiceAsset(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My voice" : name,
                               sourceType: currentReference.source, referenceAudio: currentReference.asset)
        do {
            let saved = try audioFileStore.saveVoice(voice)
            self.currentReference = CurrentReferenceAudio(asset: saved.referenceAudio, source: saved.sourceType)
            savedVoices.insert(saved, at: 0)
            statusMessage = "\(saved.name) is saved on this device with its managed reference audio."
        } catch {
            statusMessage = error.localizedDescription
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
