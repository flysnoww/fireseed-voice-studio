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