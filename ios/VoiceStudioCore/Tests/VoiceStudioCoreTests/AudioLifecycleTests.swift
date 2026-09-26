import Foundation
import XCTest
@testable import VoiceStudioCore

final class AudioLifecycleTests: XCTestCase {
    private var temporaryRoot: URL!
    private var store: AudioFileStore!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = try AudioFileStore(rootDirectory: temporaryRoot)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: temporaryRoot.path) {
            try FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testPreviewSixEvictsOldestFileFIFO() throws {
        let lifecycle = AudioLifecycle(fileStore: store)
        var made: [AudioAsset] = []
        for _ in 0..<6 {
            let asset = try makeStagedAsset()
            made.append(asset)
            try lifecycle.cache(asset, as: .preview)
        }
        XCTAssertEqual(lifecycle.cachedAssets(as: .preview).count, 5)
        XCTAssertNil(lifecycle.cachedAsset(id: made[0].id, as: .preview))
        XCTAssertThrowsError(try store.managedURL(for: made[0]))
        XCTAssertNotNil(try store.managedURL(for: made[1]))
    }

    func testGenerateThreeEvictsOldestFileFIFO() throws {
        let lifecycle = AudioLifecycle(fileStore: store)
        let first = try makeStagedAsset()
        let second = try makeStagedAsset()
        let third = try makeStagedAsset()
        try lifecycle.cache(first, as: .generated)
        try lifecycle.cache(second, as: .generated)
        try lifecycle.cache(third, as: .generated)
        XCTAssertEqual(lifecycle.cachedAssets(as: .generated).map(\.id), [second.id, third.id])
        XCTAssertThrowsError(try store.managedURL(for: first))
    }

    func testSavedAssetSurvivesLaterCacheEviction() throws {
        let lifecycle = AudioLifecycle(fileStore: store)
        let first = try makeStagedAsset()
        try lifecycle.cache(first, as: .generated)
        let saved = try XCTUnwrap(lifecycle.save(id: first.id, from: .generated))
        try lifecycle.cache(makeStagedAsset(), as: .generated)
        try lifecycle.cache(makeStagedAsset(), as: .generated)
        XCTAssertNil(lifecycle.cachedAsset(id: first.id, as: .generated))
        XCTAssertEqual(saved.persistenceState, .persistent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.managedURL(for: saved).path))
        XCTAssertEqual(store.savedAudioAssets(), [saved])
    }

    func testAudioPersistenceStateChangesOnPromotion() throws {
        let staged = try makeStagedAsset()
        XCTAssertEqual(staged.persistenceState, .temporary)
        let saved = try store.promoteToPersistent(staged)
        XCTAssertEqual(saved.persistenceState, .persistent)
        XCTAssertThrowsError(try store.managedURL(for: staged))
        XCTAssertNotNil(try store.managedURL(for: saved))
    }

    func testSavedVoiceReferencesItsManagedAudioAsset() throws {
        let staged = try makeStagedAsset()
        let voice = VoiceAsset(name: "Kitchen recording", sourceType: .record, referenceAudio: staged)
        let saved = try store.saveVoice(voice)
        XCTAssertEqual(saved.referenceAudio.id, staged.id)
        XCTAssertEqual(saved.referenceAudio.persistenceState, .persistent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.managedURL(for: saved.referenceAudio).path))
        XCTAssertEqual(store.savedVoices(), [saved])
    }

    func testVoiceSavedTimeCompatibilityDoesNotAddRequiredJSONFields() throws {
        let saved = try store.saveVoice(VoiceAsset(name: "Older voice", sourceType: .imported,
                                                   referenceAudio: makeStagedAsset()))
        let metadataURL = temporaryRoot.appendingPathComponent(
            "Metadata/voice-\(saved.id.uuidString.lowercased()).json")
        let metadata = try Data(contentsOf: metadataURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        XCTAssertNil(json["savedAt"])

        let restored = try XCTUnwrap(store.savedVoices().first)
        XCTAssertEqual(restored.name, "Older voice")
        XCTAssertEqual(restored.sourceType, .imported)
        XCTAssertEqual(restored.referenceAudio.duration, saved.referenceAudio.duration)
        XCTAssertEqual(restored.savedAt, saved.createdAt)
    }

    func testSavedVoiceReferenceResolvesAfterStoreIsRecreated() throws {
        let staged = try makeStagedAsset()
        let source = VoiceAsset(name: "Relaunch voice", sourceType: .record, referenceAudio: staged)
        let saved = try store.saveVoice(source)
        let originalURL = try store.managedURL(for: saved.referenceAudio)
        let originalBytes = try Data(contentsOf: originalURL)

        let relaunchedStore = try AudioFileStore(rootDirectory: temporaryRoot)
        let reloaded = try XCTUnwrap(relaunchedStore.savedVoices().first)
        let reloadedURL = try relaunchedStore.managedURL(for: reloaded.referenceAudio)

        XCTAssertEqual(reloaded.referenceAudio.fileName, saved.referenceAudio.fileName)
        XCTAssertEqual(reloaded.referenceAudio.persistenceState, .persistent)
        XCTAssertEqual(reloaded.sourceType, .record)
        XCTAssertEqual(reloaded.referenceAudio.duration, staged.duration)
        XCTAssertEqual(reloaded.savedAt, saved.createdAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloadedURL.path))
        XCTAssertEqual(try Data(contentsOf: reloadedURL), originalBytes)
    }

    func testDeletingVoiceRemovesMetadataAndItsExclusiveReferenceAudio() throws {
        let saved = try store.saveVoice(VoiceAsset(name: "Delete me", sourceType: .imported,
                                                   referenceAudio: makeStagedAsset()))
        let audioURL = try store.managedURL(for: saved.referenceAudio)
        let voiceMetadata = temporaryRoot.appendingPathComponent(
            "Metadata/voice-\(saved.id.uuidString.lowercased()).json")
        let audioMetadata = temporaryRoot.appendingPathComponent(
            "Metadata/audio-\(saved.referenceAudio.id.uuidString.lowercased()).json")

        try store.deleteVoice(id: saved.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: voiceMetadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioMetadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(try store.savedVoices().isEmpty)
    }

    func testDeletingVoicePreservesReferenceAudioSharedByAnotherVoice() throws {
        let saved = try store.saveVoice(VoiceAsset(name: "Shared one", sourceType: .record,
                                                   referenceAudio: makeStagedAsset()))
        let shared = try store.saveVoice(VoiceAsset(name: "Shared two", sourceType: .imported,
                                                    referenceAudio: saved.referenceAudio))
        let audioURL = try store.managedURL(for: shared.referenceAudio)

        try store.deleteVoice(id: saved.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(try store.savedVoices().map(\.id), [shared.id])
        XCTAssertNotNil(try store.managedURL(for: try XCTUnwrap(store.savedVoices().first?.referenceAudio)))

        try store.deleteVoice(id: shared.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testRelaunchUnderNewRootUsesAudioMetadataInsteadOfEmbeddedCopy() throws {
        let staged = try makeStagedAsset()
        let voice = VoiceAsset(name: "Moved voice", sourceType: .record, referenceAudio: staged)
        let saved = try store.saveVoice(voice)
        // Simulate an old Voice record retaining the pre-promotion AudioAsset.
        let voiceURL = temporaryRoot.appendingPathComponent("Metadata/voice-\(voice.id.uuidString.lowercased()).json")
        try JSONEncoder().encode(voice).write(to: voiceURL)
        let movedRoot = temporaryRoot.appendingPathComponent("RelaunchedContainer")
        try FileManager.default.createDirectory(at: movedRoot, withIntermediateDirectories: true)
        for directory in ["Metadata", "ManagedAudio"] {
            try FileManager.default.moveItem(at: temporaryRoot.appendingPathComponent(directory),
                                            to: movedRoot.appendingPathComponent(directory))
        }
        let relaunched = try AudioFileStore(rootDirectory: movedRoot)
        let loaded = try XCTUnwrap(relaunched.savedVoices().first)
        XCTAssertEqual(loaded.id, voice.id)
        XCTAssertEqual(loaded.referenceAudio, saved.referenceAudio)
        let resolved = try relaunched.managedURL(for: loaded.referenceAudio)
        XCTAssertEqual(resolved.deletingLastPathComponent().standardizedFileURL,
                       movedRoot.appendingPathComponent("ManagedAudio", isDirectory: true).standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: resolved), Data([0x01, 0x02, 0x03]))
        let metadata = try Data(contentsOf: movedRoot.appendingPathComponent("Metadata/audio-\(staged.id.uuidString.lowercased()).json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
        XCTAssertEqual(json["fileName"] as? String, saved.referenceAudio.fileName)
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains(temporaryRoot.path))
    }

    func testRelaunchRejectsMissingAudioMetadataEvenWhenEmbeddedCopyIsValid() throws {
        let saved = try store.saveVoice(VoiceAsset(name: "Missing metadata", sourceType: .record,
                                                   referenceAudio: makeStagedAsset()))
        try FileManager.default.removeItem(at: temporaryRoot.appendingPathComponent(
            "Metadata/audio-\(saved.referenceAudio.id.uuidString.lowercased()).json"))
        XCTAssertTrue(try AudioFileStore(rootDirectory: temporaryRoot).savedVoices().isEmpty)
    }

    func testRelaunchRejectsEmptyOrMissingReferenceFile() throws {
        let saved = try store.saveVoice(VoiceAsset(name: "Missing audio", sourceType: .record,
                                                   referenceAudio: makeStagedAsset()))
        let url = try store.managedURL(for: saved.referenceAudio)
        try Data().write(to: url)
        XCTAssertTrue(try AudioFileStore(rootDirectory: temporaryRoot).savedVoices().isEmpty)
        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(try AudioFileStore(rootDirectory: temporaryRoot).savedVoices().isEmpty)
    }

    func testImportCopiesFileIntoManagedStaging() throws {
        let source = temporaryRoot.appendingPathComponent("outside-source.wav")
        try Data([0x01, 0x02, 0x03]).write(to: source)
        let imported = try store.importAudio(from: source, duration: 1.25)
        try FileManager.default.removeItem(at: source)
        let managed = try store.managedURL(for: imported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.path))
        XCTAssertEqual(try Data(contentsOf: managed), Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(imported.persistenceState, .temporary)
    }

    func testUnavailableRendererReportsUnsupportedVoiceClone() async {
        let renderer = UnavailableRenderer()
        XCTAssertEqual(renderer.capabilities.support(for: .voiceClone), .unsupported)
        let request = VoiceRequest(text: "Hello", voiceID: UUID(), renderMode: .preview)
        let result = await renderer.synthesize(request)
        XCTAssertEqual(result, .unsupported(.voiceClone))
    }

    func testCanonicalVoiceRequestHasNoRendererSpecificKnobs() throws {
        let request = VoiceRequest(text: "Hello", voiceID: UUID(), language: "en",
                                   accent: "US", attributes: ["style": "calm"], renderMode: .generate)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["text", "voiceID", "language", "accent", "attributes", "renderMode"]))
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["cfg"])
        XCTAssertNil(json["seed"])
    }

    private func makeStagedAsset() throws -> AudioAsset {
        let destination = store.recordingDestination()
        try Data([0x01, 0x02, 0x03]).write(to: destination)
        return try store.registerRecording(at: destination, duration: 1.0)
    }
}
