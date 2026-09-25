import Combine
import Foundation
import VoiceStudioCore

@MainActor
final class VoiceStudioModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentAudio: AudioAsset?
    @Published private(set) var currentSource: VoiceSourceType = .record
    @Published private(set) var savedVoices: [VoiceAsset] = []
    @Published var statusMessage = "Record or import a reference audio file to create a voice."

    private let audioFileStore: AudioFileStore

    private let recorder: AudioRecorder
    private let importer: AudioImporter
    private let player: AudioPlayer

    init() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let fileStore = try AudioFileStore(rootDirectory: support.appendingPathComponent("VoiceStudio", isDirectory: true))
        self.audioFileStore = fileStore

        self.recorder = AudioRecorder(fileStore: fileStore)
        self.importer = AudioImporter(fileStore: fileStore)
        self.player = AudioPlayer(fileStore: fileStore)
        self.savedVoices = fileStore.savedVoices()
        self.player.stateHandler = { [weak self] playing in self?.isPlaying = playing }
        self.recorder.interruptionHandler = { [weak self] result in
            guard let self else { return }
            self.isRecording = false
            switch result {
            case .success(let asset):
                self.currentAudio = asset
                self.currentSource = .record
                self.statusMessage = "Recording stopped by an audio interruption. The reference is ready to play or save as a voice."
            case .failure(let error):
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func startRecording() async {
        do {
            try await recorder.startRecording()
            isRecording = true
            statusMessage = "Recording. Tap Stop recording when you are done."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        do {
            currentAudio = try recorder.stopRecording()
            currentSource = .record
            isRecording = false
            statusMessage = "Recording ready in Voice Studio. Play it or save it as a voice reference."
        } catch {
            isRecording = false
            statusMessage = error.localizedDescription
        }
    }

    func importAudio(from url: URL) {
        do {
            currentAudio = try importer.importDocument(at: url)
            currentSource = .imported
            statusMessage = "An app-managed copy is ready to play or save as a voice reference."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func playCurrentAudio() {
        guard let currentAudio else { return }
        play(currentAudio)
    }

    func playVoiceReference(_ voice: VoiceAsset) { play(voice.referenceAudio) }

    func stopPlayback() {
        player.stop()
        isPlaying = false
    }

    func saveVoice(name: String) {
        guard let currentAudio else { return }
        let voice = VoiceAsset(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My voice" : name,
                               sourceType: currentSource, referenceAudio: currentAudio)
        do {
            let saved = try audioFileStore.saveVoice(voice)
            self.currentAudio = saved.referenceAudio
            savedVoices.insert(saved, at: 0)
            statusMessage = "\(saved.name) is saved on this device with its managed reference audio."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func report(_ error: Error) { statusMessage = error.localizedDescription }

    private func play(_ asset: AudioAsset) {
        do {
            try player.play(asset)
            isPlaying = true
        } catch {
            isPlaying = false
            statusMessage = error.localizedDescription
        }
    }
}
