@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation
import VoiceStudioCore

private struct QwenPackValidationIssue: LocalizedError {
    let operation: String
    let file: String
    let expected: String
    let actual: String
    var errorDescription: String? { "\(operation) failed for \(file): expected \(expected); actual \(actual)." }
}

struct QwenPackManifest: Decodable {
    struct File: Decodable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    let format_version: Int
    let model_id: String?
    let model_revision: String
    let source_repository: String?
    let source_repository_revision: String?
    let source_model_revision_attested: Bool?
    let converter_revision: String?
    let converter_revision_attested: Bool?
    let qwen3_tts_cpp_revision: String
    let ggml_revision: String
    let quantization: String
    let files: [File]
    let pack_id: String?
    let renderer_id: String?
    let variant: String?
    let version: String?
    let compatibility_version: Int?
    let capabilities: [String: String]?
    let supported_languages: [String]?
    let supported_dialects: [String]?
}

enum QwenPackManifestDecoder {
    static func decode(_ data: Data) throws -> QwenPackManifest {
        do { return try JSONDecoder().decode(QwenPackManifest.self, from: data) }
        catch {
            let detail = decodeDetail(error)
            throw QwenPackValidationIssue(operation: "decodeManifest", file: "manifest.json",
                                          expected: detail.expected, actual: detail.actual)
        }
    }

    static func decodeDetail(_ error: Error) -> (expected: String, actual: String) {
        switch error {
        case DecodingError.keyNotFound(let key, _):
            return ("required field \(key.stringValue)", "missing")
        case DecodingError.typeMismatch(let type, let context):
            return ("\(context.codingPath.map(\.stringValue).joined(separator: ".")) as \(type)", "invalid type")
        case DecodingError.valueNotFound(let type, let context):
            return ("\(context.codingPath.map(\.stringValue).joined(separator: ".")) as \(type)", "null or missing")
        case DecodingError.dataCorrupted(let context):
            return ("valid JSON at \(context.codingPath.map(\.stringValue).joined(separator: "."))", "corrupt data")
        default:
            return ("Qwen package manifest schema", error.localizedDescription)
        }
    }
}

/// Product-facing adapter for a replaceable local renderer pack. Runtime details stay here.
actor QwenRendererAdapter: InstallableSpeechProvider, VoicePreparingSpeechProvider, SpeechRuntimeManaging {
    nonisolated static let installedPackURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RendererPacks/LocalVoice", isDirectory: true)

    nonisolated let id: SpeechProviderID = .local
    nonisolated let capabilities = CapabilityProfile(
        support: [.speechGeneration: .supported, .voiceCloning: .supported,
                  .languageSelection: .supported], languages: ["en", "zh"])
    nonisolated var installedResourceURL: URL { Self.installedPackURL }

    private let installURL: URL
    private let diagnostics: VoiceStudioDiagnostics
    private var runtime: OpaquePointer?
    private var manifest: QwenPackManifest?
    private var preparedEmbeddings: [UUID: [Float]] = [:]
    private let supportedModelRevision = "dab70521e0956e3db91fb887d36c9a07d21ebc0b"
    private let supportedRuntimeRevision = "b3ba14077cf1b3e11b86e5f84aa9184605c89b28"
    private let supportedGGMLRevision = "3af5f5760e19a96427f5f7a93b79cbdf3d4b265b"

    init(diagnostics: VoiceStudioDiagnostics) {
        self.diagnostics = diagnostics
        installURL = Self.installedPackURL
    }

    deinit {
        if let runtime { qwen3_tts_destroy(runtime) }
    }

    func installPack(at folder: URL) async throws -> CapabilityProfile {
        let securityScoped = folder.startAccessingSecurityScopedResource()
        defer { if securityScoped { folder.stopAccessingSecurityScopedResource() } }
        let validationStarted = ProcessInfo.processInfo.systemUptime
        await diagnostics.start(.packValidation)
        let source: QwenPackManifest
        do {
            source = try validate(folder)
            await diagnostics.finish(.packValidation, startedAt: validationStarted)
            await diagnostics.update {
                $0.pack = "valid"
                $0.packID = source.pack_id ?? "Qwen3-TTS-0.6B"
                $0.packFilesFound = ["manifest.json"] + source.files.map(\.path)
            }
        } catch {
            await diagnostics.finish(.packValidation, startedAt: validationStarted, error: error,
                                     friendlyError: "This local speech component is invalid or incompatible.",
                                     operation: (error as? QwenPackValidationIssue)?.operation,
                                     file: (error as? QwenPackValidationIssue)?.file,
                                     expected: (error as? QwenPackValidationIssue)?.expected,
                                     actual: (error as? QwenPackValidationIssue)?.actual)
            await diagnostics.update { $0.pack = "invalid"; $0.runtime = "not loaded" }
            throw error
        }
        let replacing = folder.standardizedFileURL != installURL.standardizedFileURL
        let importStarted = ProcessInfo.processInfo.systemUptime
        await diagnostics.start(.packImport)
        await diagnostics.update { $0.pack = "importing" }
        let backup: URL?
        do {
            backup = replacing ? try replaceInstalledPack(from: folder, files: source.files) : nil
            await diagnostics.finish(.packImport, startedAt: importStarted)
            await diagnostics.update { $0.pack = "imported" }
        } catch {
            await diagnostics.finish(.packImport, startedAt: importStarted, error: error,
                                     friendlyError: "Could not import the local speech component.",
                                     operation: (error as? QwenPackValidationIssue)?.operation ?? "copyPack",
                                     file: (error as? QwenPackValidationIssue)?.file ?? "pack contents",
                                     expected: (error as? QwenPackValidationIssue)?.expected ?? "manifest and required model files copied intact",
                                     actual: (error as? QwenPackValidationIssue)?.actual ?? error.localizedDescription)
            throw error
        }
        let loadStarted = ProcessInfo.processInfo.systemUptime
        await diagnostics.start(.runtimeLoad)
        await diagnostics.update {
            $0.runtime = "loading"
            $0.backend = "CPU"
            $0.runtimeModelLocation = "Application Support/RendererPacks/LocalVoice"
        }
        do {
            try loadRuntime()
            await diagnostics.finish(.runtimeLoad, startedAt: loadStarted)
            let backend = runtime.map { String(cString: qwen3_tts_active_backend_name($0)) } ?? "unknown"
            await diagnostics.update { $0.runtime = "loaded"; $0.backend = backend }
        } catch {
            await diagnostics.finish(.runtimeLoad, startedAt: loadStarted, error: error,
                                     friendlyError: "Could not load local speech. Please try again.")
            await diagnostics.update { $0.runtime = "failed"; $0.backend = "CPU" }
            if replacing {
                try? FileManager.default.removeItem(at: installURL)
                if let backup { try? FileManager.default.moveItem(at: backup, to: installURL) }
                try? loadRuntime()
            }
            throw error
        }
        if let backup { try? FileManager.default.removeItem(at: backup) }
        manifest = source
        preparedEmbeddings.removeAll()
        return capabilities
    }

    func generate(_ request: VoiceRequest, voice: VoiceAsset?, referenceAudioURL: URL?) async -> SpeechResult {
        guard let runtime else { return .failure("Speech provider is not ready.") }
        guard case .saved(let voiceID) = request.voice,
              let voice, voice.id == voiceID, let referenceAudioURL else {
            return .unsupported(.voiceCloning)
        }
        guard request.renderMode == .generate else { return .unsupported(.speechGeneration) }
        guard let languageID = Self.languageID(for: request.language) else {
            return .failure("Choose a supported speech language.")
        }
        guard let embedding = preparedEmbeddings[voiceID] else {
            return .failure("Confirm this voice before generating.")
        }
        var params = Qwen3TtsParams()
        qwen3_tts_default_params(&params)
        params.n_threads = 4
        params.language_id = languageID
        params.max_audio_tokens = 240
        let result: UnsafeMutablePointer<Qwen3TtsAudio>? = embedding.withUnsafeBufferPointer { values in
            request.text.withCString { text in
                qwen3_tts_synthesize_with_embedding(runtime, text, values.baseAddress,
                                                    Int32(values.count), &params)
            }
        }
        guard let result else {
            return .failure(runtimeError(runtime, fallback: "Synthesis failed."))
        }
        defer { qwen3_tts_free_audio(result) }
        guard result.pointee.n_samples > 0, result.pointee.sample_rate > 0 else {
            return .failure("Speech generation failed. Please try again.")
        }
        let samples = Array(UnsafeBufferPointer(start: result.pointee.samples,
                                                count: Int(result.pointee.n_samples)))
        guard !samples.isEmpty, let wav = try? writeWave(samples: samples,
                                                         sampleRate: Int(result.pointee.sample_rate)) else {
            return .failure("Generated audio could not be saved. Please try again.")
        }
        return .renderedFile(wav, duration: Double(samples.count) / Double(result.pointee.sample_rate),
                             approximation: nil)
    }

    func prepareVoice(_ voice: VoiceAsset, referenceAudioURL: URL) async throws {
        guard let runtime else { throw providerError(code: 20, "Local runtime is not loaded.") }
        await diagnostics.updateVoicePrepareOperation("validateReference", physicalFootprintMB: Self.physicalFootprintMB())
        let normalized = try normalizeReferenceAudio(referenceAudioURL)
        defer { try? FileManager.default.removeItem(at: normalized) }
        let normalizedInfo = try AVAudioFile(forReading: normalized)
        let attributes = try FileManager.default.attributesOfItem(atPath: normalized.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let sampleRate = Int(normalizedInfo.fileFormat.sampleRate)
        let channelCount = normalizedInfo.fileFormat.channelCount
        let duration = Double(normalizedInfo.length) / normalizedInfo.fileFormat.sampleRate
        guard byteCount > 44, sampleRate == 24_000, channelCount == 1,
              normalizedInfo.fileFormat.commonFormat == .pcmFormatInt16,
              duration.isFinite, duration > 0 else {
            throw providerError(code: 23, "Managed reference did not normalize to readable 24 kHz mono Int16 PCM WAV.")
        }
        await diagnostics.updateVoicePrepareOperation(
            "prepareReference", referenceFormat: "WAV PCM Int16 · 24000 Hz · mono · \(byteCount) bytes · \(String(format: "%.2f", duration)) s",
            physicalFootprintMB: Self.physicalFootprintMB())
        var embedding = [Float](repeating: 0, count: 4096)
        await diagnostics.updateVoicePrepareOperation("speakerEncode", physicalFootprintMB: Self.physicalFootprintMB())
        let count = normalized.path.withCString { path in
            embedding.withUnsafeMutableBufferPointer { buffer in
                qwen3_tts_extract_embedding_file(runtime, path, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard count > 0 else {
            throw providerError(code: 21, runtimeError(runtime, fallback: "Reference preparation failed."))
        }
        embedding.removeSubrange(Int(count)..<embedding.count)
        preparedEmbeddings[voice.id] = embedding
        await diagnostics.updateVoicePrepareOperation("cacheWrite", physicalFootprintMB: Self.physicalFootprintMB())
    }

    func unloadRuntime() async {
        if let runtime { qwen3_tts_destroy(runtime) }
        runtime = nil
        preparedEmbeddings.removeAll()
        await diagnostics.update { $0.runtime = "not loaded" }
    }

    private func validate(_ folder: URL) throws -> QwenPackManifest {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let data: Data
        do { data = try Data(contentsOf: manifestURL) }
        catch {
            let issue = error as NSError
            throw QwenPackValidationIssue(operation: "readManifest", file: "manifest.json",
                                          expected: "readable JSON manifest",
                                          actual: "\(issue.domain)/\(issue.code): \(issue.localizedDescription)")
        }
        let pack: QwenPackManifest
        pack = try QwenPackManifestDecoder.decode(data)
        guard pack.format_version == 1,
              pack.model_id == nil || pack.model_id == "Qwen/Qwen3-TTS-12Hz-0.6B-Base",
              ((pack.model_revision == supportedModelRevision && pack.source_model_revision_attested != false) ||
               (pack.source_repository == "TeALO/qwen3-tts-gguf" &&
                pack.source_repository_revision == "ee2fe152f14b4ec8b06c393969c3416246366833" &&
                pack.source_model_revision_attested == false)),
              pack.qwen3_tts_cpp_revision == supportedRuntimeRevision,
              pack.ggml_revision == supportedGGMLRevision,
              ["F16", "Q8_0"].contains(pack.quantization),
              (pack.compatibility_version == nil || pack.compatibility_version == 1),
              (pack.capabilities == nil || pack.capabilities == Self.expectedPackCapabilities),
              (pack.supported_languages == nil || (pack.supported_languages!.contains("en") && pack.supported_languages!.contains("zh"))),
              (pack.pack_id?.isEmpty != true), (pack.renderer_id?.isEmpty != true),
              (pack.variant?.isEmpty != true), (pack.version?.isEmpty != true) else {
            throw QwenPackValidationIssue(operation: "validateManifest", file: "manifest.json",
                                          expected: "pinned Qwen 0.6B Base / F16 package revisions and capabilities",
                                          actual: "manifest metadata is incompatible with the supported package contract")
        }
        let expectedModel = pack.quantization == "Q8_0" ? "qwen3-tts-0.6b-q8_0.gguf" : "qwen3-tts-0.6b-f16.gguf"
        let expectedNames = [expectedModel, "qwen3-tts-tokenizer-f16.gguf"]
        guard Set(pack.files.map(\.path)) == Set(expectedNames) else {
            throw QwenPackValidationIssue(operation: "validateFileList", file: "manifest.json",
                                          expected: expectedNames.sorted().joined(separator: ", "),
                                          actual: pack.files.map(\.path).sorted().joined(separator: ", "))
        }
        for name in expectedNames {
            guard let file = pack.files.first(where: { $0.path == name }), file.bytes > 0,
                  file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw QwenPackValidationIssue(operation: "validateFileEntry", file: name,
                                              expected: "positive byte count and 64-character SHA-256",
                                              actual: "missing or invalid manifest file entry")
            }
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  Int64(values.fileSize ?? -1) == file.bytes else {
                let foundSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(String.init) ?? "unreadable"
                throw QwenPackValidationIssue(operation: "validateFileSize", file: name,
                                              expected: "\(file.bytes) bytes", actual: "\(foundSize) bytes")
            }
            let hash: String
            do { hash = try Self.sha256(of: url) }
            catch {
                let issue = error as NSError
                throw QwenPackValidationIssue(operation: "readSHA256", file: name,
                                              expected: "readable model asset", actual: "\(issue.domain)/\(issue.code): \(issue.localizedDescription)")
            }
            guard hash == file.sha256.lowercased() else {
                throw QwenPackValidationIssue(operation: "validateSHA256", file: name,
                                              expected: file.sha256.lowercased(), actual: hash)
            }
        }
        return pack
    }

    private func replaceInstalledPack(from source: URL, files: [QwenPackManifest.File]) throws -> URL? {
        let manager = FileManager.default
        let parent = installURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("LocalVoice-import-\(UUID().uuidString)", isDirectory: true)
        let backup = parent.appendingPathComponent("LocalVoice-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        for file in files + [QwenPackManifest.File(path: "manifest.json", bytes: 0, sha256: "")] {
            try manager.copyItem(at: source.appendingPathComponent(file.path),
                                 to: staging.appendingPathComponent(file.path))
        }
        _ = try validate(staging)
        var hadPrevious = false
        if manager.fileExists(atPath: installURL.path) {
            try manager.moveItem(at: installURL, to: backup)
            hadPrevious = true
        }
        do {
            try manager.moveItem(at: staging, to: installURL)
        } catch {
            if hadPrevious { try? manager.moveItem(at: backup, to: installURL) }
            throw error
        }
        return hadPrevious ? backup : nil
    }

    private func loadRuntime() throws {
        if let runtime { qwen3_tts_destroy(runtime); self.runtime = nil }
        setenv("QWEN3_TTS_BACKEND", "cpu", 1)
        let next = installURL.path.withCString { qwen3_tts_create($0, 4) }
        guard let next else {
            let raw = String(cString: qwen3_tts_last_create_error())
            throw providerError(code: 22, raw.isEmpty ? "Qwen runtime returned no initialization detail." : raw)
        }
        runtime = next
    }

    private static let expectedPackCapabilities: [String: String] = [
        "voice_clone": "supported", "voice_design": "unsupported", "timbre_control": "unsupported",
        "emotion_control": "unsupported", "accent_control": "unsupported", "speed_control": "unsupported",
        "instruction_control": "unsupported", "language_selection": "supported", "dialect_control": "unsupported",
        "reference_transcript_conditioning": "unsupported", "local": "supported"
    ]

    func normalizeReferenceAudio(_ sourceURL: URL) throws -> URL {
        let source = try AVAudioFile(forReading: sourceURL)
        guard source.length > 0, source.length <= Int64(UInt32.max),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(source.length)) else {
            throw providerError(code: 25, "Could not allocate the source reference audio buffer.")
        }
        do {
            try source.read(into: inputBuffer)
        } catch {
            let detail = error as NSError
            throw providerError(code: 28,
                                "Could not read source reference audio (\(detail.domain) \(detail.code)): \(detail.localizedDescription)")
        }
        guard inputBuffer.frameLength > 0 else { throw VoiceStudioError.invalidAudioFile }
        // Match the true-device Spike's known-good 24 kHz mono 16-bit PCM input.
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                         channels: 1, interleaved: true) else {
            throw providerError(code: 24, "Could not create the required reference audio format.")
        }
        guard let converter = AVAudioConverter(from: source.processingFormat, to: target) else {
            throw VoiceStudioError.invalidAudioFile
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-reference-\(UUID().uuidString).wav")
        do {
            let output: AVAudioFile
            do {
                output = try AVAudioFile(forWriting: destination, settings: target.settings,
                                         commonFormat: target.commonFormat, interleaved: target.isInterleaved)
            } catch {
                let detail = error as NSError
                throw providerError(code: 29,
                                    "Could not create PCM WAV writer (\(detail.domain) \(detail.code)): \(detail.localizedDescription)")
            }
            guard let converted = AVAudioPCMBuffer(pcmFormat: target,
                                                   frameCapacity: AVAudioFrameCount(target.sampleRate * 5)) else {
                throw providerError(code: 25, "Could not allocate reference audio buffers.")
            }
            var reachedEndOfStream = false
            var didProvideInput = false
            while !reachedEndOfStream {
                converted.frameLength = 0
                var conversionError: NSError?
                let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                    guard !didProvideInput else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    didProvideInput = true
                    inputStatus.pointee = .haveData
                    return inputBuffer
                }
                if let conversionError {
                    throw NSError(domain: "VoiceStudio.AudioConversion", code: conversionError.code,
                                  userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter failed (\(conversionError.domain) \(conversionError.code)): \(conversionError.localizedDescription)",
                                             NSUnderlyingErrorKey: conversionError])
                }
                if converted.frameLength > 0 {
                    do {
                        try output.write(from: converted)
                    } catch {
                        let detail = error as NSError
                        throw providerError(code: 30,
                                            "Could not write normalized PCM WAV (\(detail.domain) \(detail.code)): \(detail.localizedDescription)")
                    }
                }
                switch status {
                case .endOfStream:
                    reachedEndOfStream = true
                case .error:
                    throw VoiceStudioError.invalidAudioFile
                case .haveData, .inputRanDry:
                    guard converted.frameLength > 0 else {
                        throw providerError(code: 26, "Audio conversion stopped before producing output.")
                    }
                @unknown default:
                    throw VoiceStudioError.invalidAudioFile
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw VoiceStudioError.missingManagedAudio
        }
        return destination
    }

    private static func physicalFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint / 1_048_576)
    }

    private func runtimeError(_ runtime: OpaquePointer, fallback: String) -> String {
        let detail = String(cString: qwen3_tts_get_error(runtime))
        return detail.isEmpty ? fallback : detail
    }

    private func providerError(code: Int, _ message: String) -> NSError {
        NSError(domain: "VoiceStudio.LocalSpeech", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func writeWave(samples: [Float], sampleRate: Int) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                   channels: 1, interleaved: false)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("generated-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].assign(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
        return url
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func languageID(for language: String?) -> Int32? {
        guard let language else { return nil }
        let primary = language.lowercased().split(separator: "-").first.map(String.init)
        switch primary {
        case "en": return 2050
        case "zh": return 2055
        default: return nil
        }
    }
}
