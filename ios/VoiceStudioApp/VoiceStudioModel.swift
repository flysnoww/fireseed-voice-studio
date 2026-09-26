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
    static func canSave(hasCurrentReference: Bool, isRecording: Bool, isRequestingPermission: Bool,
                        isSavingVoice: Bool = false) -> Bool {
        hasCurrentReference && !isRecording && !isRequestingPermission && !isSavingVoice
    }
}

@MainActor
final class VoiceStudioModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isRequestingPermission = false
    @Published private(set) var microphonePermissionDenied = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isSavingVoice = false
    @Published private(set) var currentReference: CurrentReferenceAudio?
    @Published private(set) var savedVoices: [VoiceAsset] = []
    @Published private(set) var savedVoiceFilter: SavedVoiceFilter = .time
    @Published private(set) var savedVoicePage = 0
    @Published var statusMessage = "Record or import a reference audio file to create a voice."

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
