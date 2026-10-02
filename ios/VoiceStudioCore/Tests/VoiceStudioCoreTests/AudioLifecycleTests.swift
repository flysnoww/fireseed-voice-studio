import Foundation
import CryptoKit
import XCTest
@testable import VoiceStudioCore

final class AudioLifecycleTests: XCTestCase {
    func testImitationMetadataSurvivesSaveRenameAndRelaunchAndLegacyDefaults() throws {
        let source = try makeStagedAsset()
        let id = UUID()
        let output = try store.registerGeneratedAudio(from: store.managedURL(for: source), duration: 1,
            sourceVoiceID: id, text: "", generationKind: .imitationSameContent, referencePerformanceID: source.id)
        let saved = try store.promoteToPersistent(output)
        _ = try store.updateSavedAudio(id: saved.id, displayName: "Imitation")
        let restored = try AudioFileStore(rootDirectory: temporaryRoot).savedAudioAssets().first { $0.id == saved.id }
        XCTAssertEqual(restored?.generationKind, .imitationSameContent)
        XCTAssertEqual(restored?.referencePerformanceID, source.id)
        XCTAssertEqual(restored?.sourceVoiceID, id)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "generationKind"); json.removeValue(forKey: "referencePerformanceID")
        let legacy = try JSONDecoder().decode(AudioAsset.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.generationKind, .normal)
        XCTAssertNil(legacy.referencePerformanceID)
    }
    func testOperationLeaseSurvivesSourceEvictionAndClosesIdempotently() throws {
        let asset = try makeStagedAsset()
        let lease = try AudioFileLease(source: store.managedURL(for: asset), root: temporaryRoot)
        let bytes = try Data(contentsOf: lease.url)
        try store.removeTemporaryAudio(asset)
        XCTAssertEqual(try Data(contentsOf: lease.url), bytes)
        lease.close(); lease.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))
    }

    func testLegacyVoiceProfileMigratesAndUpdatedProfilePreservesDurableAssets() throws {
        let saved = try store.saveVoice(VoiceAsset(name: "Legacy name", sourceType: .imported,
                                                    referenceAudio: makeStagedAsset(), languageHint: "zh", defaultAccent: "zh-CN"))
        let referenceURL = try store.managedURL(for: saved.referenceAudio)
        let bytes = try Data(contentsOf: referenceURL)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "profile")
        let legacy = try JSONDecoder().decode(VoiceAsset.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.profile, VoiceProfile(language: "zh", accent: "zh-CN"))
        let profile = VoiceProfile(speed: 1.25, pitch: 200, language: "en", accent: "en-GB")
        let updated = try store.updateVoiceProfile(id: saved.id, profile: profile)
        XCTAssertEqual(updated.profile, profile)
        XCTAssertEqual(updated.referenceAudio, saved.referenceAudio)
        XCTAssertEqual(updated.name, saved.name)
        let relaunched = try AudioFileStore(rootDirectory: temporaryRoot)
        XCTAssertEqual(relaunched.savedVoices().first?.profile, profile)
        XCTAssertEqual(try Data(contentsOf: relaunched.managedURL(for: updated.referenceAudio)), bytes)
        XCTAssertThrowsError(try store.updateVoiceProfile(id: saved.id, profile: VoiceProfile(speed: .nan)))
        XCTAssertEqual(store.savedVoices().first?.profile, profile)
    }
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

    func testGeneratedSpeechIsManagedThenPersistentAcrossRelaunch() throws {
        let source = temporaryRoot.appendingPathComponent("renderer-output.wav")
        try Data([0x10, 0x20, 0x30]).write(to: source)
        let voiceID = UUID()
        let generated = try store.registerGeneratedAudio(from: source, duration: 2.5,
                                                         sourceVoiceID: voiceID, text: "Hello")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(generated.persistenceState, .temporary)
        XCTAssertEqual(generated.sourceVoiceID, voiceID)
        XCTAssertEqual(generated.text, "Hello")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.managedURL(for: generated).path))

        let lifecycle = AudioLifecycle(fileStore: store)
        try lifecycle.cache(generated, as: .generated)
        let saved = try XCTUnwrap(lifecycle.save(id: generated.id, from: .generated))
        let relaunched = try AudioFileStore(rootDirectory: temporaryRoot)
        XCTAssertEqual(relaunched.savedAudioAssets(), [saved])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try relaunched.managedURL(for: saved).path))
    }

    func testGeneratedAudioMetadataCanBeRenamedFavoritedSharedAndDeletedSafely() throws {
        let source = temporaryRoot.appendingPathComponent("renderer-output.wav")
        try Data([0x10, 0x20, 0x30]).write(to: source)
        let generated = try store.registerGeneratedAudio(from: source, duration: 2.5,
                                                        sourceVoice: .systemVoice("voice.id"),
                                                        language: "en-US", text: "A generated line")
        let lifecycle = AudioLifecycle(fileStore: store)
        try lifecycle.cache(generated, as: .generated)
        let saved = try XCTUnwrap(lifecycle.save(id: generated.id, from: .generated))
        let shareURL = try store.managedURL(for: saved)
        XCTAssertEqual(try Data(contentsOf: shareURL), Data([0x10, 0x20, 0x30]))

        let renamed = try store.updateSavedAudio(id: saved.id, displayName: "Greeting", isFavorite: true)
        XCTAssertEqual(renamed.displayName, "Greeting")
        XCTAssertTrue(renamed.isFavorite)
        let restored = try AudioFileStore(rootDirectory: temporaryRoot).savedAudioAssets()
        XCTAssertEqual(restored, [renamed])
        XCTAssertEqual(restored.first?.sourceVoice, .systemVoice("voice.id"))
        XCTAssertEqual(restored.first?.language, "en-US")

        try store.deleteSavedAudio(id: saved.id)
        XCTAssertTrue(store.savedAudioAssets().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shareURL.path))
    }

    func testGeneratedAudioDeletionPreservesFileReferencedBySavedVoice() throws {
        let source = temporaryRoot.appendingPathComponent("renderer-output.wav")
        try Data([0x10, 0x20, 0x30]).write(to: source)
        let generated = try store.registerGeneratedAudio(from: source, duration: 2.5,
                                                        sourceVoice: .tinyLocalVoice("tiny-local"), text: "Hello")
        let lifecycle = AudioLifecycle(fileStore: store)
        try lifecycle.cache(generated, as: .generated)
        let savedAudio = try XCTUnwrap(lifecycle.save(id: generated.id, from: .generated))
        _ = try store.saveVoice(VoiceAsset(name: "Uses audio", sourceType: .record, referenceAudio: savedAudio))
        let audioURL = try store.managedURL(for: savedAudio)

        XCTAssertThrowsError(try store.deleteSavedAudio(id: savedAudio.id)) { error in
            XCTAssertEqual(error as? VoiceStudioError, .assetIsReferenced)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testGeneratedAudioLibrarySortsNewestFirstAndPagesTenItems() {
        var assets: [AudioAsset] = []
        for index in 0..<12 {
            assets.append(AudioAsset(fileName: "\(UUID().uuidString.lowercased()).wav", duration: 1,
                                     createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                                     text: "Clip \(index)", persistenceState: .persistent))
        }
        let ordered = assets.sorted { $0.createdAt > $1.createdAt }
        XCTAssertEqual(GeneratedAudioOrdering.pageSize, 10)
        XCTAssertEqual(GeneratedAudioOrdering.newestFirst(assets).first?.id, ordered.first?.id)
        XCTAssertEqual(GeneratedAudioOrdering.page(GeneratedAudioOrdering.newestFirst(assets), index: 0).count, 10)
        XCTAssertEqual(GeneratedAudioOrdering.page(GeneratedAudioOrdering.newestFirst(assets), index: 1).count, 2)
    }

    func testRemovingRendererPackDoesNotAffectSavedVoiceOrReference() throws {
        let saved = try store.saveVoice(VoiceAsset(name: "Independent voice", sourceType: .record,
                                                   referenceAudio: makeStagedAsset()))
        let rendererFolder = temporaryRoot.appendingPathComponent("RendererPacks/Standard", isDirectory: true)
        try FileManager.default.createDirectory(at: rendererFolder, withIntermediateDirectories: true)
        try Data([0x01]).write(to: rendererFolder.appendingPathComponent("pack-marker"))
        try FileManager.default.removeItem(at: rendererFolder)

        let restored = try XCTUnwrap(AudioFileStore(rootDirectory: temporaryRoot).savedVoices().first)
        XCTAssertEqual(restored.id, saved.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.managedURL(for: restored.referenceAudio).path))
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
        let provider = UnavailableSpeechProvider()
        XCTAssertEqual(provider.capabilities.status(for: .voiceCloning), .unsupported)
        let request = VoiceRequest(text: "Hello", voiceID: UUID(), renderMode: .preview)
        let result = await provider.generate(request, voice: nil, referenceAudioURL: nil)
        XCTAssertEqual(result, .unsupported(.speechGeneration))
    }

    func testCanonicalVoiceRequestHasNoRendererSpecificKnobs() throws {
        let request = VoiceRequest(text: "Hello", voice: .systemDefault, language: "en-US",
                                   accent: "en-US", shaping: VoiceShaping(values: [.bright: 0.4]),
                                   expression: .gentle, speed: 1.15, pitch: 100, renderMode: .generate)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["text", "voice", "language", "accent", "shaping",
                                            "expression", "speed", "pitch", "renderMode"]))
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["cfg"])
        XCTAssertNil(json["seed"])
    }

    func testOpenVoicePackValidatesPinnedFilesInstallsAndDeletesOnlyPackAndCache() throws {
        let source = temporaryRoot.appendingPathComponent("openvoice-source", isDirectory: true)
        let encoderFile = source.appendingPathComponent("OpenVoice_SpeakerEncoder.mlpackage/Manifest.json")
        let converterFile = source.appendingPathComponent("OpenVoice_VoiceConverter.mlpackage/Manifest.json")
        try FileManager.default.createDirectory(at: encoderFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: converterFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("encoder fixture".utf8).write(to: encoderFile)
        try Data("converter fixture".utf8).write(to: converterFile)
        let manifest = OpenVoicePackManifest(
            sourceRepository: OpenVoicePackStore.sourceRepository,
            sourceRevision: OpenVoicePackStore.sourceRevision,
            converterRepository: OpenVoicePackStore.converterRepository,
            converterRevision: OpenVoicePackStore.converterRevision,
            license: "MIT", computeUnits: "cpuAndGPU",
            files: [fileEntry(encoderFile, relativeTo: source), fileEntry(converterFile, relativeTo: source)])
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))

        let packStore = makeOpenVoicePackStore(for: manifest)
        XCTAssertEqual(try packStore.validate(at: source), manifest)
        try packStore.install(from: source)
        XCTAssertEqual(try packStore.validateInstalled(), manifest)

        let stagedReference = try makeStagedAsset()
        let savedVoice = try store.saveVoice(VoiceAsset(name: "Durable", sourceType: .record,
                                                        referenceAudio: stagedReference))
        let referenceURL = try store.managedURL(for: savedVoice.referenceAudio)
        let cache = OpenVoiceSpeakerEmbeddingCache(rootDirectory: packStore.cacheDirectory)
        let packRevision = OpenVoicePackStore.converterRevision
        try cache.store([0.1, -0.2, 0.3], voiceID: savedVoice.id,
                        referenceAudioID: savedVoice.referenceAudio.id, packRevision: packRevision)
        XCTAssertEqual(cache.load(voiceID: savedVoice.id,
                                  referenceAudioID: savedVoice.referenceAudio.id,
                                  packRevision: packRevision), [0.1, -0.2, 0.3])
        XCTAssertNil(cache.load(voiceID: savedVoice.id,
                                referenceAudioID: UUID(), packRevision: packRevision))

        try packStore.deleteInstalledPack()
        XCTAssertThrowsError(try packStore.validateInstalled())
        XCTAssertNil(cache.load(voiceID: savedVoice.id,
                                referenceAudioID: savedVoice.referenceAudio.id,
                                packRevision: packRevision))
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenceURL.path))
        XCTAssertEqual(try store.savedVoices().first?.referenceAudio.id, savedVoice.referenceAudio.id)
    }

    func testOpenVoicePackRejectsTamperingAndUnsafePaths() throws {
        let source = temporaryRoot.appendingPathComponent("openvoice-invalid", isDirectory: true)
        let encoderFile = source.appendingPathComponent("OpenVoice_SpeakerEncoder.mlpackage/Manifest.json")
        let converterFile = source.appendingPathComponent("OpenVoice_VoiceConverter.mlpackage/Manifest.json")
        try FileManager.default.createDirectory(at: encoderFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: converterFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("encoder".utf8).write(to: encoderFile)
        try Data("converter".utf8).write(to: converterFile)
        var files = [fileEntry(encoderFile, relativeTo: source), fileEntry(converterFile, relativeTo: source)]
        files[0] = OpenVoicePackManifest.File(path: "OpenVoice_SpeakerEncoder.mlpackage/../escape", bytes: 1,
                                             sha256: String(repeating: "0", count: 64))
        let manifest = OpenVoicePackManifest(
            sourceRepository: OpenVoicePackStore.sourceRepository,
            sourceRevision: OpenVoicePackStore.sourceRevision,
            converterRepository: OpenVoicePackStore.converterRepository,
            converterRevision: OpenVoicePackStore.converterRevision,
            license: "MIT", computeUnits: "cpuAndGPU", files: files)
        try JSONEncoder().encode(manifest).write(to: source.appendingPathComponent("manifest.json"))
        let packStore = makeOpenVoicePackStore(for: manifest)
        XCTAssertThrowsError(try packStore.validate(at: source)) { error in
            XCTAssertEqual(error as? OpenVoicePackError,
                           .unsafePath("OpenVoice_SpeakerEncoder.mlpackage/../escape"))
        }
    }

    private func fileEntry(_ url: URL, relativeTo root: URL) -> OpenVoicePackManifest.File {
        let data = try! Data(contentsOf: url)
        let relative = String(url.path.dropFirst(root.path.count + 1)).replacingOccurrences(of: "\\", with: "/")
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return OpenVoicePackManifest.File(path: relative, bytes: Int64(data.count), sha256: digest)
    }

    private func makeOpenVoicePackStore(for manifest: OpenVoicePackManifest) -> OpenVoicePackStore {
        let contract = Dictionary(uniqueKeysWithValues: manifest.files.map {
            ($0.path, OpenVoicePackStore.PinnedFile(bytes: $0.bytes, sha256: $0.sha256))
        })
        return OpenVoicePackStore(rootDirectory: temporaryRoot.appendingPathComponent("RendererPacks"),
                                  sourceRevision: manifest.sourceRevision,
                                  converterRevision: manifest.converterRevision,
                                  expectedFiles: contract)
    }

    private func makeStagedAsset() throws -> AudioAsset {
        let destination = store.recordingDestination()
        try Data([0x01, 0x02, 0x03]).write(to: destination)
        return try store.registerRecording(at: destination, duration: 1.0)
    }
}
