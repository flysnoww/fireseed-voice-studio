import XCTest
import VoiceStudioCore
@testable import VoiceStudio

final class VoiceStudioAppTests: XCTestCase {
    func testRendererIsExplicitlyUnavailableInM1() async {
        let renderer = UnavailableRenderer()
        XCTAssertEqual(renderer.capabilities.support(for: .voiceClone), .unsupported)
        let request = VoiceRequest(text: "Hello", voiceID: UUID(), renderMode: .preview)
        let result = await renderer.synthesize(request)
        XCTAssertEqual(result, .unsupported(.voiceClone))
    }

    @MainActor
    func testRecordDeniedDoesNotImportOrStartAndShowsSettingsState() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let permissions = StubMicrophonePermissionClient(status: .denied)
        let importer = StubAudioImporter(asset: AudioAsset(fileName: "\(UUID().uuidString.lowercased()).wav", duration: 1))
        let model = try VoiceStudioModel(rootDirectory: root,
                                         microphonePermissionClient: permissions,
                                         audioImporter: importer)

        await model.startRecording()

        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(model.isReferenceReady)
        XCTAssertFalse(model.canSaveVoice)
        XCTAssertTrue(model.microphonePermissionDenied)
        XCTAssertTrue(model.statusMessage.contains("Settings"))
        XCTAssertEqual(permissions.requestCount, 0)
        XCTAssertEqual(importer.callCount, 0)
        let stagedFiles = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("StagedAudio").path)
        XCTAssertTrue(stagedFiles.isEmpty)
    }

    @MainActor
    func testUndeterminedPermissionIsRequestedOnceAndDeniedStateDoesNotRepeatPrompt() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let permissions = StubMicrophonePermissionClient(status: .undetermined, requestResult: false)
        let model = try VoiceStudioModel(rootDirectory: root, microphonePermissionClient: permissions)

        await model.startRecording()
        await model.startRecording()

        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertFalse(model.isRecording)
        XCTAssertTrue(model.microphonePermissionDenied)
        XCTAssertTrue(model.statusMessage.contains("Open Settings"))
    }

    @MainActor
    func testImportCreatesCurrentReferenceAndEnablesSaveWithoutRequestingMicrophone() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudioFileStore(rootDirectory: root)
        let asset = try makeStagedAsset(in: store)
        let permissions = StubMicrophonePermissionClient(status: .undetermined)
        let importer = StubAudioImporter(asset: asset)
        let model = try VoiceStudioModel(rootDirectory: root,
                                         microphonePermissionClient: permissions,
                                         audioImporter: importer)

        model.importAudio(from: root.appendingPathComponent("selected.wav"))

        XCTAssertEqual(importer.callCount, 1)
        XCTAssertEqual(permissions.requestCount, 0)
        XCTAssertTrue(model.isReferenceReady)
        XCTAssertTrue(model.canSaveVoice)
        XCTAssertEqual(model.currentReference?.sourceLabel, "Imported")

        model.saveVoice(name: "Imported reference")
        XCTAssertEqual(model.savedVoices.count, 1)
        XCTAssertEqual(model.savedVoices.first?.sourceType.rawValue, VoiceSourceType.imported.rawValue)
        XCTAssertNil(model.currentReference)
        XCTAssertFalse(model.canSaveVoice)
        model.saveVoice(name: "Duplicate")
        XCTAssertEqual(model.savedVoices.count, 1)
        let savedURL = try store.managedURL(for: try XCTUnwrap(model.savedVoices.first?.referenceAudio))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
    }

    @MainActor
    func testRecordedReferenceUsesSameReadyStateAndDoesNotImport() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudioFileStore(rootDirectory: root)
        let asset = try makeStagedAsset(in: store)
        let recorder = StubAudioRecorder(asset: asset)
        let importer = StubAudioImporter(asset: asset)
        let model = try VoiceStudioModel(rootDirectory: root,
                                         audioRecorder: recorder,
                                         audioImporter: importer)

        await model.startRecording()
        XCTAssertTrue(model.isRecording)
        model.stopRecording()

        XCTAssertFalse(model.isRecording)
        XCTAssertTrue(model.isReferenceReady)
        XCTAssertTrue(model.canSaveVoice)
        XCTAssertEqual(model.currentReference?.sourceLabel, "Recorded")
        XCTAssertEqual(importer.callCount, 0)
    }

    func testSaveVoiceAvailabilityRequiresAReadyIdleReference() {
        XCTAssertFalse(VoiceAvailabilityPolicy.canSave(hasCurrentReference: false,
                                                        isRecording: false,
                                                        isRequestingPermission: false))
        XCTAssertTrue(VoiceAvailabilityPolicy.canSave(hasCurrentReference: true,
                                                       isRecording: false,
                                                       isRequestingPermission: false))
        XCTAssertFalse(VoiceAvailabilityPolicy.canSave(hasCurrentReference: true,
                                                        isRecording: true,
                                                        isRequestingPermission: false))
        XCTAssertFalse(VoiceAvailabilityPolicy.canSave(hasCurrentReference: true,
                                                        isRecording: false,
                                                        isRequestingPermission: true))
    }

    @MainActor
    func testSavedVoiceReferenceReloadsWhenAppModelIsRecreated() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudioFileStore(rootDirectory: root)
        let asset = try makeStagedAsset(in: store)
        var model: VoiceStudioModel? = try VoiceStudioModel(rootDirectory: root,
                                                            audioImporter: StubAudioImporter(asset: asset))
        model?.importAudio(from: root.appendingPathComponent("selected.wav"))
        model?.saveVoice(name: "Relaunch")
        let saved = try XCTUnwrap(model?.savedVoices.first)
        model = nil
        let relaunched = try VoiceStudioModel(rootDirectory: root)
        let loaded = try XCTUnwrap(relaunched.savedVoices.first)
        XCTAssertEqual(loaded.id, saved.id)
        XCTAssertEqual(loaded.referenceAudio.id, saved.referenceAudio.id)
        XCTAssertEqual(loaded.referenceAudio.persistenceState, .persistent)
        XCTAssertEqual(try Data(contentsOf: store.managedURL(for: loaded.referenceAudio)),
                       Data([0x01, 0x02, 0x03]))
        XCTAssertNil(relaunched.currentReference)
        relaunched.playVoiceReference(loaded)
    }

    @MainActor
    func testSaveFailurePreservesCurrentReferenceAndAllowsRetry() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudioFileStore(rootDirectory: root)
        let asset = try makeStagedAsset(in: store)
        let model = try VoiceStudioModel(rootDirectory: root, audioImporter: StubAudioImporter(asset: asset))
        model.importAudio(from: root.appendingPathComponent("selected.wav"))

        try FileManager.default.removeItem(at: store.managedURL(for: asset))
        model.saveVoice(name: "Retry me")

        XCTAssertEqual(model.currentReference?.asset.id, asset.id)
        XCTAssertTrue(model.canSaveVoice)
        XCTAssertTrue(model.savedVoices.isEmpty)
        XCTAssertFalse(model.statusMessage.isEmpty)
    }

    @MainActor
    func testReferenceCannotBeSavedOrReplacedWhileRecording() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudioFileStore(rootDirectory: root)
        let asset = try makeStagedAsset(in: store)
        let recorder = StubAudioRecorder(asset: asset)
        let importer = StubAudioImporter(asset: asset)
        let model = try VoiceStudioModel(rootDirectory: root, audioRecorder: recorder, audioImporter: importer)
        model.importAudio(from: root.appendingPathComponent("selected.wav"))
        XCTAssertTrue(model.canSaveVoice)
        await model.startRecording()
        await model.startRecording()
        XCTAssertEqual(recorder.startCount, 1)
        XCTAssertFalse(model.canSaveVoice)
        model.saveVoice(name: "Must not save")
        model.importAudio(from: root.appendingPathComponent("other.wav"))
        XCTAssertTrue(model.savedVoices.isEmpty)
        XCTAssertEqual(importer.callCount, 1)
        model.stopRecording()
        XCTAssertTrue(model.canSaveVoice)
        model.saveVoice(name: "Recorded")
        XCTAssertEqual(model.savedVoices.count, 1)
    }

    @MainActor
    func testSaveAndImportBlockedDuringPermissionRequestThenRecoverAfterDenial() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudioFileStore(rootDirectory: root)
        let asset = try makeStagedAsset(in: store)
        let permissions = PendingMicrophonePermissionClient()
        let importer = StubAudioImporter(asset: asset)
        let model = try VoiceStudioModel(rootDirectory: root,
                                         microphonePermissionClient: permissions, audioImporter: importer)
        model.importAudio(from: root.appendingPathComponent("selected.wav"))
        let started = expectation(description: "Permission request started")
        permissions.onRequest = { started.fulfill() }
        let task = Task { await model.startRecording() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isRequestingPermission)
        XCTAssertFalse(model.canSaveVoice)
        model.saveVoice(name: "Blocked")
        model.importAudio(from: root.appendingPathComponent("other.wav"))
        await model.startRecording()
        XCTAssertEqual(permissions.requestCount, 1)
        XCTAssertEqual(importer.callCount, 1)
        XCTAssertTrue(model.savedVoices.isEmpty)
        permissions.finishDenied()
        await task.value
        XCTAssertFalse(model.isRequestingPermission)
        XCTAssertFalse(model.isRecording)
        XCTAssertTrue(model.microphonePermissionDenied)
        XCTAssertTrue(model.canSaveVoice)
        XCTAssertEqual(model.currentReference?.asset.id, asset.id)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStagedAsset(in store: AudioFileStore) throws -> AudioAsset {
        let destination = store.recordingDestination()
        try Data([0x01, 0x02, 0x03]).write(to: destination)
        return try store.registerRecording(at: destination, duration: 1)
    }
}

@MainActor
private final class StubMicrophonePermissionClient: MicrophonePermissionClient {
    var status: MicrophonePermissionStatus
    private let requestResult: Bool
    private(set) var requestCount = 0

    init(status: MicrophonePermissionStatus, requestResult: Bool = false) {
        self.status = status
        self.requestResult = requestResult
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        status = requestResult ? .granted : .denied
        return requestResult
    }
}


@MainActor
private final class StubAudioImporter: AudioImporting {
    let asset: AudioAsset
    private(set) var callCount = 0

    init(asset: AudioAsset) { self.asset = asset }

    func importDocument(at externalURL: URL) throws -> AudioAsset {
        callCount += 1
        return asset
    }
}

@MainActor
private final class StubAudioRecorder: AudioRecording {
    let asset: AudioAsset
    var interruptionHandler: (@MainActor (Result<AudioAsset, Error>) -> Void)?

    init(asset: AudioAsset) { self.asset = asset }

    private(set) var startCount = 0
    func startRecording() async throws { startCount += 1 }
    func stopRecording() throws -> AudioAsset { asset }
}

@MainActor
private final class PendingMicrophonePermissionClient: MicrophonePermissionClient {
    var status: MicrophonePermissionStatus = .undetermined
    var onRequest: (() -> Void)?
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestAccess() async -> Bool {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            onRequest?()
        }
    }

    func finishDenied() {
        status = .denied
        continuation?.resume(returning: false)
        continuation = nil
    }
}
