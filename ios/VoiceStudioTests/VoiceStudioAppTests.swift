import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
import VoiceStudioCore
@testable import VoiceStudio

final class VoiceStudioAppTests: XCTestCase {
    @MainActor
    func testAppLanguageDefaultsToSystemAndPersistsExplicitSelections() {
        let defaults = makeLanguageDefaults()
        let key = UUID().uuidString
        let initial = AppLanguagePreference(defaults: defaults, key: key)
        XCTAssertEqual(initial.language, .system)
        XCTAssertTrue(initial.language.usesSystemLocale)

        initial.set(.english)
        XCTAssertFalse(initial.language.usesSystemLocale)
        XCTAssertEqual(AppLanguagePreference(defaults: defaults, key: key).language, .english)
        initial.set(.simplifiedChinese)
        XCTAssertEqual(AppLanguagePreference(defaults: defaults, key: key).language, .simplifiedChinese)
    }

    @MainActor
    func testAppearanceDefaultsAndPersistsSkinAndBackgroundIndependently() throws {
        let defaults = makeLanguageDefaults()
        let skinKey = UUID().uuidString
        let backgroundKey = UUID().uuidString
        let folder = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: folder) }

        let initial = AppAppearancePreference(defaults: defaults, skinKey: skinKey,
                                               backgroundKey: backgroundKey, appearanceDirectory: folder)
        XCTAssertEqual(initial.skin, .frost)
        XCTAssertNil(initial.backgroundImageURL)
        initial.setSkin(.warm)
        try initial.saveBackgroundImage(makeBackgroundImage(orientation: 1, color: .systemBlue))

        let restored = AppAppearancePreference(defaults: defaults, skinKey: skinKey,
                                               backgroundKey: backgroundKey, appearanceDirectory: folder)
        XCTAssertEqual(restored.skin, .warm)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(restored.backgroundImageURL).path))
        restored.clearBackgroundImage()
        XCTAssertEqual(restored.skin, .warm)
        XCTAssertNil(restored.backgroundImageURL)
    }

    @MainActor
    func testBackgroundImageNormalizationCorrectsOrientationPersistsAndReplaces() throws {
        let defaults = makeLanguageDefaults()
        let key = UUID().uuidString
        let folder = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: folder) }
        let appearance = AppAppearancePreference(defaults: defaults, backgroundKey: key,
                                                 appearanceDirectory: folder)

        try appearance.saveBackgroundImage(makeBackgroundImage(orientation: 6, color: .systemBlue))
        let firstURL = try XCTUnwrap(appearance.backgroundImageURL)
        let firstData = try Data(contentsOf: firstURL)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(firstData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        let normalizedCGImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(try XCTUnwrap(normalizedCGImage.colorSpace).name as String?, CGColorSpace.sRGB)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 120)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 80)

        try appearance.saveBackgroundImage(makeBackgroundImage(orientation: 1, color: .systemRed))
        XCTAssertEqual(appearance.backgroundImageURL, firstURL)
        XCTAssertNotEqual(try Data(contentsOf: firstURL), firstData)
        XCTAssertEqual(AppAppearancePreference(defaults: defaults, backgroundKey: key,
                                               appearanceDirectory: folder).backgroundImageURL, firstURL)
        appearance.clearBackgroundImage()
        XCTAssertNil(appearance.backgroundImageURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
    }

    @MainActor
    func testInvalidBackgroundImageReportsFailureAndPreservesExistingImage() throws {
        let defaults = makeLanguageDefaults()
        let key = UUID().uuidString
        let folder = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: folder) }
        let appearance = AppAppearancePreference(defaults: defaults, backgroundKey: key,
                                                 appearanceDirectory: folder)
        try appearance.saveBackgroundImage(makeBackgroundImage(orientation: 1, color: .systemGreen))
        let url = try XCTUnwrap(appearance.backgroundImageURL)
        let saved = try Data(contentsOf: url)

        XCTAssertThrowsError(try appearance.saveBackgroundImage(Data([0xFF, 0xD8, 0xFF, 0xD9])))
        XCTAssertEqual(appearance.backgroundImageURL, url)
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testBackgroundNormalizerConvertsPNGToManagedJPEG() throws {
        let normalized = try BackgroundImageNormalizer.normalize(makeBackgroundImage(orientation: 1, color: .systemOrange,
                                                                                     type: UTType.png))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(normalized as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    func testBackgroundNormalizerAcceptsHEICWhenEncoderIsAvailable() throws {
        guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(UTType.heic.identifier) == true else {
            throw XCTSkip("HEIC encoder is unavailable on this test runtime.")
        }
        let heic = makeBackgroundImage(orientation: 1, color: .systemPurple, type: UTType.heic)
        XCTAssertNoThrow(try BackgroundImageNormalizer.normalize(heic))
    }

    func testQwenManifestDecoderAcceptsSpikeCoreContractAndOptionalProductMetadata() throws {
        let manifest = """
        {"format_version":1,"model_revision":"dab70521e0956e3db91fb887d36c9a07d21ebc0b",
         "qwen3_tts_cpp_revision":"b3ba14077cf1b3e11b86e5f84aa9184605c89b28",
         "ggml_revision":"3af5f5760e19a96427f5f7a93b79cbdf3d4b265b","quantization":"F16",
         "files":[{"path":"qwen3-tts-0.6b-f16.gguf","bytes":1,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
                  {"path":"qwen3-tts-tokenizer-f16.gguf","bytes":1,"sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}
        """.data(using: .utf8)!

        let decoded = try QwenPackManifestDecoder.decode(manifest)

        XCTAssertNil(decoded.model_id)
        XCTAssertNil(decoded.pack_id)
        XCTAssertEqual(decoded.files.map(\.path), ["qwen3-tts-0.6b-f16.gguf", "qwen3-tts-tokenizer-f16.gguf"])
    }

    func testQwenManifestDecoderReportsMissingRequiredField() throws {
        let full = """
        {"format_version":1,"model_revision":"dab70521e0956e3db91fb887d36c9a07d21ebc0b",
         "qwen3_tts_cpp_revision":"b3ba14077cf1b3e11b86e5f84aa9184605c89b28",
         "ggml_revision":"3af5f5760e19a96427f5f7a93b79cbdf3d4b265b","quantization":"F16","files":[]}
        """.data(using: .utf8)!
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: full) as? [String: Any])
        object.removeValue(forKey: "ggml_revision")
        let missingRequiredField = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try QwenPackManifestDecoder.decode(missingRequiredField)) { error in
            XCTAssertTrue(error.localizedDescription.contains("required field ggml_revision"))
            XCTAssertTrue(error.localizedDescription.contains("missing"))
        }
    }

    @MainActor
    func testLanguagePreferenceIsIndependentOfSavedVoiceState() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudioFileStore(rootDirectory: root)
        let asset = try makeStagedAsset(in: store)
        let model = try VoiceStudioModel(rootDirectory: root, audioImporter: StubAudioImporter(asset: asset))
        model.importAudio(from: root.appendingPathComponent("selected.wav"))
        model.saveVoice(name: "Recorded Voice")
        let savedID = try XCTUnwrap(model.savedVoices.first?.id)

        let defaults = makeLanguageDefaults()
        let preference = AppLanguagePreference(defaults: defaults, key: UUID().uuidString)
        preference.set(.simplifiedChinese)

        XCTAssertEqual(model.savedVoices.map(\.id), [savedID])
        XCTAssertEqual(model.savedVoices.first?.name, "Recorded Voice")
        XCTAssertNil(model.currentReference)
    }

    func testSavedVoiceLibrarySortsFiltersAndPagesEightAtATime() throws {
        let voices = (0..<17).map { index in
            VoiceAsset(id: UUID(), name: "Voice \(index)",
                       sourceType: index.isMultiple(of: 2) ? .record : .imported,
                       referenceAudio: AudioAsset(fileName: "\(UUID().uuidString.lowercased()).wav",
                                                  duration: 12.4, persistenceState: .persistent),
                       createdAt: Date(timeIntervalSince1970: Double(index)),
                       updatedAt: Date(timeIntervalSince1970: Double(index)))
        }
        let sorted = SavedVoiceLibrary.voices(voices, matching: .time)
        XCTAssertEqual(sorted.first?.name, "Voice 16")
        XCTAssertEqual(SavedVoiceLibrary.pageSize, 8)
        XCTAssertEqual(SavedVoiceLibrary.page(sorted, index: 0).count, 8)
        XCTAssertEqual(SavedVoiceLibrary.page(sorted, index: 1).count, 8)
        XCTAssertEqual(SavedVoiceLibrary.page(sorted, index: 2).count, 1)
        XCTAssertEqual(SavedVoiceLibrary.voices(voices, matching: .imported).count, 8)
        XCTAssertEqual(SavedVoiceLibrary.voices(voices, matching: .recorded).count, 9)
        XCTAssertTrue(SavedVoiceLibrary.voices(voices, matching: .recorded).allSatisfy { $0.sourceType == .record })
        XCTAssertEqual(SavedVoiceLibrary.formattedDuration(125.9), "02:05")
        XCTAssertEqual(SavedVoiceLibrary.formattedDuration(.infinity), "00:00")
    }

    @MainActor
    func testImportedDurationComesFromAudioFileAndSurvivesVoiceSave() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudioFileStore(rootDirectory: root)
        let source = root.appendingPathComponent("duration-check.wav")
        try makeSilentWaveFile(at: source, duration: 0.5)

        let imported = try AudioImporter(fileStore: store).importDocument(at: source)
        XCTAssertEqual(imported.duration, 0.5, accuracy: 0.05)
        let saved = try store.saveVoice(VoiceAsset(name: "Measured duration", sourceType: .imported,
                                                   referenceAudio: imported))
        let restored = try XCTUnwrap(AudioFileStore(rootDirectory: root).savedVoices().first)
        XCTAssertEqual(restored.referenceAudio.duration, saved.referenceAudio.duration)
    }

    @MainActor
    func testSavedVoiceFilterResetsPageAndDeletingLastPageClampsIt() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let voices = try makePersistedVoices(in: root, count: 9)
        let model = try VoiceStudioModel(rootDirectory: root)
        XCTAssertEqual(model.savedVoices.count, 9)
        XCTAssertEqual(model.savedVoicePageCount, 2)
        model.setSavedVoicePage(1)
        XCTAssertEqual(model.pagedSavedVoices.count, 1)
        model.setSavedVoiceFilter(.imported)
        XCTAssertEqual(model.savedVoicePage, 0)

        model.setSavedVoiceFilter(.time)
        model.setSavedVoicePage(1)
        let lastVoice = try XCTUnwrap(model.pagedSavedVoices.first)
        model.deleteSavedVoice(id: lastVoice.id)

        XCTAssertEqual(model.savedVoicePage, 0)
        XCTAssertEqual(model.pagedSavedVoices.count, 8)
        XCTAssertEqual(try AudioFileStore(rootDirectory: root).savedVoices().count, 8)
        XCTAssertEqual(voices.count, 9)
    }

    @MainActor
    func testSavingVoiceFromSecondPageReturnsToNewestOnFirstPage() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makePersistedVoices(in: root, count: 9)
        let store = try AudioFileStore(rootDirectory: root)
        let staged = try makeStagedAsset(in: store)
        let model = try VoiceStudioModel(rootDirectory: root, audioImporter: StubAudioImporter(asset: staged))
        model.setSavedVoicePage(1)
        model.importAudio(from: root.appendingPathComponent("selected.wav"))

        model.saveVoice(name: "Newest custom voice")

        XCTAssertEqual(model.savedVoicePage, 0)
        XCTAssertEqual(model.pagedSavedVoices.first?.name, "Newest custom voice")
        XCTAssertEqual(model.pagedSavedVoices.count, 8)
    }

    @MainActor
    func testWhitespaceOnlyVoiceNameCannotBeSaved() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudioFileStore(rootDirectory: root)
        let asset = try makeStagedAsset(in: store)
        let model = try VoiceStudioModel(rootDirectory: root, audioImporter: StubAudioImporter(asset: asset))
        model.importAudio(from: root.appendingPathComponent("selected.wav"))

        model.saveVoice(name: " \n  ")

        XCTAssertTrue(model.canSaveVoice)
        XCTAssertEqual(model.currentReference?.asset.id, asset.id)
        XCTAssertTrue(model.savedVoices.isEmpty)
    }

    func testUnavailableSpeechProviderDoesNotClaimGenerationSupport() async {
        let provider = UnavailableSpeechProvider()
        XCTAssertEqual(provider.capabilities.status(for: .speechGeneration), .unsupported)
        let request = VoiceRequest(text: "Hello", voice: .systemDefault, renderMode: .preview)
        let result = await provider.generate(request, voice: nil, referenceAudioURL: nil)
        XCTAssertEqual(result, .unsupported(.speechGeneration))
    }

    @MainActor
    func testTinyLocalProviderUsesSharedGeneratedAudioPipelineWithoutReferenceVoice() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("tiny-output.wav")
        try makeSilentWaveFile(at: source, duration: 0.5)
        let tiny = StubTinyLocalSpeechProvider(outputURL: source, duration: 0.5)
        let local = StubLocalSpeechProvider()
        let assembly = SpeechProviderAssembly(providers: [.system: UnavailableSpeechProvider(),
                                                          .tinyLocal: tiny],
                                              localPackProvider: local)
        let model = try VoiceStudioModel(rootDirectory: root, providerAssembly: assembly)

        XCTAssertTrue(model.canGenerate(text: "Hello", voice: .tinyLocal, language: "en"))
        XCTAssertEqual(model.capabilities(for: .tinyLocal).status(for: .voiceCloning), .unsupported)
        model.updateDiagnosticContext(voice: .tinyLocal, language: "en", accent: nil,
                                      hasText: true, hasCurrentReference: false)
        await model.generateSpeech(text: "Hello", voice: .tinyLocal, language: "en", accent: nil)

        let generated = try XCTUnwrap(model.generatedAudio)
        XCTAssertGreaterThan(generated.duration, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try AudioFileStore(rootDirectory: root).managedURL(for: generated).path))
        XCTAssertEqual(model.diagnostics.snapshot.provider, "Tiny local")
        XCTAssertEqual(model.diagnostics.snapshot.generation, "success")
        XCTAssertNotNil(model.diagnostics.snapshot.realTimeFactor)
    }

    @MainActor
    func testShapingAndExpressionStayUnavailableUntilProviderSupportsThem() throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try VoiceStudioModel(rootDirectory: root)
        let capabilities = model.capabilities(for: .systemDefault)

        XCTAssertTrue(capabilities.shaping.isEmpty)
        XCTAssertTrue(capabilities.expressions.isEmpty)
        XCTAssertEqual(capabilities.status(for: .speed), .supported)
        XCTAssertEqual(capabilities.status(for: .pitch), .supported)
    }

    @MainActor
    func testDiagnosticsKeepStageOrderAndRedactPrivatePathsWithoutCopyingInputText() {
        let diagnostics = VoiceStudioDiagnostics()
        diagnostics.update {
            $0.provider = "Local"
            $0.pack = "valid"
            $0.runtime = "loaded"
            $0.language = "zh"
            $0.request = "ready"
        }
        let packStarted = ProcessInfo.processInfo.systemUptime
        diagnostics.start(.packValidation)
        diagnostics.finish(.packValidation, startedAt: packStarted,
                           error: NSError(domain: "VoiceStudio.LocalSpeech", code: 4865,
                                          userInfo: [NSLocalizedDescriptionKey: "Manifest field missing."]),
                           friendlyError: "Package validation failed.", operation: "decodeManifest",
                           file: "manifest.json", expected: "required field model_revision", actual: "missing")
        let loadStarted = ProcessInfo.processInfo.systemUptime
        diagnostics.start(.runtimeLoad)
        diagnostics.finish(.runtimeLoad, startedAt: loadStarted,
                           error: NSError(domain: "QwenRuntime", code: 42,
                                          userInfo: [NSLocalizedDescriptionKey: "Cannot open /Users/private/Model/secret.gguf"]),
                           friendlyError: "Could not load local speech.")

        XCTAssertEqual(diagnostics.stages.map(\.stage), [.packValidation, .runtimeLoad])
        XCTAssertEqual(diagnostics.stages.map(\.state), [.failed, .failed])
        let exported = diagnostics.exportText()
        XCTAssertTrue(exported.contains("Friendly error: Could not load local speech."))
        XCTAssertTrue(exported.contains("Error domain: QwenRuntime"))
        XCTAssertTrue(exported.contains("Error code: 42"))
        XCTAssertTrue(exported.contains("Operation: decodeManifest"))
        XCTAssertTrue(exported.contains("File: manifest.json"))
        XCTAssertTrue(exported.contains("Expected: required field model_revision"))
        XCTAssertTrue(exported.contains("Actual: missing"))
        XCTAssertTrue(exported.contains("[private path]"))
        XCTAssertFalse(exported.contains("/Users/private"))
        XCTAssertFalse(exported.contains("private user text"))

        diagnostics.finish(.output, startedAt: ProcessInfo.processInfo.systemUptime,
                           error: NSError(domain: "LocalFile", code: 9,
                                          userInfo: [NSLocalizedDescriptionKey: "Cannot read C:\\Users\\Private\\AppData\\reference.wav"]),
                           friendlyError: "Output failed.")
        let windowsPathExport = diagnostics.exportText()
        XCTAssertTrue(windowsPathExport.contains("[private path]"))
        XCTAssertFalse(windowsPathExport.contains("C:\\Users\\Private"))
    }

    func testKeyboardDismissalIgnoresTapsInsideTextInputsAndDismissesOutside() {
        let frame = CGRect(x: 20, y: 40, width: 280, height: 90)

        XCTAssertFalse(KeyboardDismissalPolicy.shouldDismiss(tapLocation: CGPoint(x: 100, y: 70),
                                                              inputFrames: [frame]))
        XCTAssertTrue(KeyboardDismissalPolicy.shouldDismiss(tapLocation: CGPoint(x: 340, y: 70),
                                                             inputFrames: [frame]))
    }

    @MainActor
    func testLocalSavedVoiceRequiresExplicitPrepareAndKeepsCanonicalAudioDurableOnFailure() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AudioFileStore(rootDirectory: root)
        let staged = try makeStagedAsset(in: store)
        let saved = try store.saveVoice(VoiceAsset(name: "Prepare test", sourceType: .record,
                                                   referenceAudio: staged))
        let local = StubLocalSpeechProvider(failFirstPrepare: true)
        let system = UnavailableSpeechProvider()
        let assembly = SpeechProviderAssembly(providers: [.system: system, .local: local],
                                              localPackProvider: local)
        let model = try VoiceStudioModel(rootDirectory: root, providerAssembly: assembly)
        await model.installLocalSpeechResource(from: root)
        let selection = VoiceSelection.saved(saved.id)
        XCTAssertFalse(model.canGenerate(text: "hello", voice: selection, language: "en"))

        await model.prepareVoice(selection, language: "en")
        XCTAssertEqual(model.voicePreparationState, .failed)
        XCTAssertFalse(model.canGenerate(text: "hello", voice: selection, language: "en"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.managedURL(for: saved.referenceAudio).path))

        await model.prepareVoice(selection, language: "en")
        XCTAssertEqual(model.preparationState(for: selection), .ready)
        XCTAssertTrue(model.canGenerate(text: "hello", voice: selection, language: "en"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.managedURL(for: saved.referenceAudio).path))
        XCTAssertEqual(model.savedVoices.first?.referenceAudio.id, saved.referenceAudio.id)
    }

    func testAppleSystemSpeechProviderProducesPlayableAudioForSharedRequest() async throws {
        let provider = AppleSystemSpeechProvider()
        guard let language = provider.capabilities.languages.first(where: { $0.hasPrefix("en") }),
              let accent = provider.capabilities.accents(for: language).first else {
            throw XCTSkip("This simulator has no English system speech voice.")
        }
        let request = VoiceRequest(text: "Hello from Voice Studio", voice: .systemDefault,
                                   language: language, accent: accent, renderMode: .generate)

        let result = await provider.generate(request, voice: nil, referenceAudioURL: nil)

        guard case .renderedFile(let url, let duration, _) = result else {
            XCTFail("Expected system speech to produce an audio file, got \(result)")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertGreaterThan(duration, 0)
    }

    func testAppleTimePitchProcessorRendersAdjustedAudioFile() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("time-pitch-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: source) }
        try makeSilentWaveFile(at: source, duration: 0.25)

        let rendered = try AudioTimePitchProcessor().process(source, speed: 1.1, pitch: 100)

        defer { if rendered != source { try? FileManager.default.removeItem(at: rendered) } }
        XCTAssertNotEqual(rendered, source)
        XCTAssertGreaterThan(try AVAudioFile(forReading: rendered).length, 0)
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
        XCTAssertEqual(model.savedVoices.first?.name, "Imported reference")
        XCTAssertEqual(model.mostRecentlySavedVoiceID, model.savedVoices.first?.id)
        XCTAssertEqual(model.savedVoices.first?.sourceType.rawValue, VoiceSourceType.imported.rawValue)
        XCTAssertEqual(model.savedVoices.first?.referenceAudio.duration, asset.duration)
        XCTAssertEqual(model.savedVoices.first?.savedAt, model.savedVoices.first?.createdAt)
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
        model.saveVoice(name: "Custom recorded name")
        XCTAssertEqual(model.savedVoices.first?.name, "Custom recorded name")
        XCTAssertEqual(model.savedVoices.first?.sourceType, .record)
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
        XCTAssertEqual(loaded.name, saved.name)
        XCTAssertEqual(loaded.referenceAudio.id, saved.referenceAudio.id)
        XCTAssertEqual(loaded.referenceAudio.persistenceState, .persistent)
        XCTAssertEqual(loaded.sourceType, saved.sourceType)
        XCTAssertEqual(loaded.referenceAudio.duration, saved.referenceAudio.duration)
        XCTAssertEqual(loaded.savedAt, saved.savedAt)
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

    private func makeLanguageDefaults() -> UserDefaults {
        let suite = "VoiceStudioTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStagedAsset(in store: AudioFileStore) throws -> AudioAsset {
        let destination = store.recordingDestination()
        try Data([0x01, 0x02, 0x03]).write(to: destination)
        return try store.registerRecording(at: destination, duration: 1)
    }

    private func makePersistedVoices(in root: URL, count: Int) throws -> [VoiceAsset] {
        let store = try AudioFileStore(rootDirectory: root)
        for index in 0..<count {
            let source: VoiceSourceType = index.isMultiple(of: 2) ? .record : .imported
            let staged = try makeStagedAsset(in: store)
            _ = try store.saveVoice(VoiceAsset(name: "Saved \(index)", sourceType: source,
                                               referenceAudio: staged))
        }
        return try store.savedVoices()
    }

    private func makeSilentWaveFile(at url: URL, duration: TimeInterval) throws {
        let sampleRate: UInt32 = 8_000
        let sampleCount = UInt32(Double(sampleRate) * duration)
        let audioBytes = sampleCount * 2
        var data = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36) + audioBytes, to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * 2, to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(audioBytes, to: &data)
        data.append(Data(repeating: 0, count: Int(audioBytes)))
        try data.write(to: url)
    }

    private func makeBackgroundImage(orientation: UInt32, color: UIColor,
                                    type: UTType = UTType.jpeg) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120))
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 120))
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image.cgImage!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0x00ff))
        data.append(UInt8(value >> 8))
    }

    private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8((value >> UInt32(shift)) & 0x000000ff))
        }
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

private actor StubLocalSpeechProvider: InstallableSpeechProvider, VoicePreparingSpeechProvider {
    nonisolated let id: SpeechProviderID = .local
    nonisolated let capabilities = CapabilityProfile(
        support: [.speechGeneration: .supported, .voiceCloning: .supported,
                  .languageSelection: .supported], languages: ["en", "zh"])
    nonisolated var installedResourceURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stub-local-pack", isDirectory: true)
    }

    private var shouldFailFirstPrepare: Bool

    init(failFirstPrepare: Bool = false) { shouldFailFirstPrepare = failFirstPrepare }

    func installPack(at folder: URL) async throws -> CapabilityProfile { capabilities }

    func prepareVoice(_ voice: VoiceAsset, referenceAudioURL: URL) async throws {
        if shouldFailFirstPrepare {
            shouldFailFirstPrepare = false
            throw NSError(domain: "StubLocalProvider", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Reference prepare test failure."])
        }
        guard FileManager.default.fileExists(atPath: referenceAudioURL.path) else {
            throw VoiceStudioError.missingManagedAudio
        }
    }

    func generate(_ request: VoiceRequest, voice: VoiceAsset?, referenceAudioURL: URL?) async -> SpeechResult {
        .unsupported(.speechGeneration)
    }
}

private actor StubTinyLocalSpeechProvider: SpeechProvider {
    nonisolated let id: SpeechProviderID = .tinyLocal
    nonisolated let capabilities = CapabilityProfile(
        support: [.speechGeneration: .supported, .voiceCloning: .unsupported,
                  .languageSelection: .supported], languages: ["en"])
    private let outputURL: URL
    private let duration: TimeInterval

    init(outputURL: URL, duration: TimeInterval) {
        self.outputURL = outputURL
        self.duration = duration
    }

    func generate(_ request: VoiceRequest, voice: VoiceAsset?, referenceAudioURL: URL?) async -> SpeechResult {
        guard case .tinyLocal = request.voice, voice == nil, referenceAudioURL == nil else {
            return .unsupported(.voiceCloning)
        }
        return .renderedFile(outputURL, duration: duration, approximation: nil)
    }
}
