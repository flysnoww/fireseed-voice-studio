import AVFoundation
import CryptoKit
import Darwin
import Foundation
import VoiceStudioCore

private struct QwenPackManifest: Decodable {
    struct File: Decodable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    let format_version: Int
    let model_id: String
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
    let pack_id: String
    let renderer_id: String
    let variant: String
    let version: String
    let compatibility_version: Int
    let capabilities: [String: String]
    let supported_languages: [String]
    let supported_dialects: [String]
}

/// Product-facing adapter for a replaceable local renderer pack. Runtime details stay here.
actor QwenRendererAdapter: InstallableSpeechProvider {
    nonisolated static let installedPackURL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RendererPacks/LocalVoice", isDirectory: true)

    nonisolated let id: SpeechProviderID = .local
    nonisolated let capabilities = CapabilityProfile(
        support: [.speechGeneration: .supported, .voiceCloning: .supported,
                  .languageSelection: .supported], languages: ["en", "zh"])
    nonisolated var installedResourceURL: URL { Self.installedPackURL }

    private let installURL: URL
    private var runtime: OpaquePointer?
    private var manifest: QwenPackManifest?
    private let supportedModelRevision = "dab70521e0956e3db91fb887d36c9a07d21ebc0b"
    private let supportedRuntimeRevision = "b3ba14077cf1b3e11b86e5f84aa9184605c89b28"
    private let supportedGGMLRevision = "3af5f5760e19a96427f5f7a93b79cbdf3d4b265b"

    init() {
        installURL = Self.installedPackURL
    }

    deinit {
        if let runtime { qwen3_tts_destroy(runtime) }
    }

    func installPack(at folder: URL) async throws -> CapabilityProfile {
        let securityScoped = folder.startAccessingSecurityScopedResource()
        defer { if securityScoped { folder.stopAccessingSecurityScopedResource() } }
        let source = try validate(folder)
        let replacing = folder.standardizedFileURL != installURL.standardizedFileURL
        let backup = replacing ? try replaceInstalledPack(from: folder, files: source.files) : nil
        do {
            try loadRuntime()
        } catch {
            if replacing {
                try? FileManager.default.removeItem(at: installURL)
                if let backup { try? FileManager.default.moveItem(at: backup, to: installURL) }
                try? loadRuntime()
            }
            throw error
        }
        if let backup { try? FileManager.default.removeItem(at: backup) }
        manifest = source
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
        let normalized: URL
        do { normalized = try normalizeReferenceAudio(referenceAudioURL) }
        catch { return .failure("This saved voice could not be prepared for speech generation.") }
        defer { try? FileManager.default.removeItem(at: normalized) }
        var embedding = [Float](repeating: 0, count: 4096)
        let embeddingSize = normalized.path.withCString { path in
            embedding.withUnsafeMutableBufferPointer { buffer in
                qwen3_tts_extract_embedding_file(runtime, path, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard embeddingSize > 0 else { return .failure("This saved voice could not be prepared for speech generation.") }
        embedding.removeSubrange(Int(embeddingSize)..<embedding.count)
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
            return .failure("Speech generation failed. Please try again.")
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

    private func validate(_ folder: URL) throws -> QwenPackManifest {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let pack = try JSONDecoder().decode(QwenPackManifest.self, from: data)
        guard pack.format_version == 1,
              pack.model_id == "Qwen/Qwen3-TTS-12Hz-0.6B-Base",
              ((pack.model_revision == supportedModelRevision && pack.source_model_revision_attested != false) ||
               (pack.source_repository == "TeALO/qwen3-tts-gguf" &&
                pack.source_repository_revision == "ee2fe152f14b4ec8b06c393969c3416246366833" &&
                pack.source_model_revision_attested == false)),
              pack.qwen3_tts_cpp_revision == supportedRuntimeRevision,
              pack.ggml_revision == supportedGGMLRevision,
              ["F16", "Q8_0"].contains(pack.quantization),
              pack.compatibility_version == 1,
              pack.capabilities == Self.expectedPackCapabilities,
              pack.supported_languages.contains("en"), pack.supported_languages.contains("zh"),
              !pack.pack_id.isEmpty, !pack.renderer_id.isEmpty,
              !pack.variant.isEmpty, !pack.version.isEmpty else {
            throw VoiceStudioError.invalidRendererPack
        }
        let expectedModel = pack.quantization == "Q8_0" ? "qwen3-tts-0.6b-q8_0.gguf" : "qwen3-tts-0.6b-f16.gguf"
        let expectedNames = [expectedModel, "qwen3-tts-tokenizer-f16.gguf"]
        guard Set(pack.files.map(\.path)) == Set(expectedNames),
              expectedNames.allSatisfy({ name in
                  guard let file = pack.files.first(where: { $0.path == name }), file.bytes > 0,
                        file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit }) else { return false }
                  let url = folder.appendingPathComponent(name)
                  guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                        Int64(values.fileSize ?? -1) == file.bytes,
                        let hash = try? Self.sha256(of: url) else { return false }
                  return hash == file.sha256.lowercased()
              }) else {
            throw VoiceStudioError.invalidRendererPack
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
        guard let next else { throw VoiceStudioError.rendererUnavailable }
        runtime = next
    }

    private static let expectedPackCapabilities: [String: String] = [
        "voice_clone": "supported", "voice_design": "unsupported", "timbre_control": "unsupported",
        "emotion_control": "unsupported", "accent_control": "unsupported", "speed_control": "unsupported",
        "instruction_control": "unsupported", "language_selection": "supported", "dialect_control": "unsupported",
        "reference_transcript_conditioning": "unsupported", "local": "supported"
    ]

    private func normalizeReferenceAudio(_ sourceURL: URL) throws -> URL {
        let source = try AVAudioFile(forReading: sourceURL)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                   channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source.processingFormat, to: target) else {
            throw VoiceStudioError.invalidAudioFile
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-reference-\(UUID().uuidString).wav")
        let output = try AVAudioFile(forWriting: destination, settings: target.settings)
        while true {
            let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096)!
            try source.read(into: input)
            if input.frameLength == 0 { break }
            var didProvideInput = false
            var conversionError: NSError?
            let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)!
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                guard !didProvideInput else { inputStatus.pointee = .noDataNow; return nil }
                didProvideInput = true
                inputStatus.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            if converted.frameLength > 0 { try output.write(from: converted) }
            if status == .error { throw VoiceStudioError.invalidAudioFile }
        }
        return destination
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
        case "en": 2050
        case "zh": 2055
        default: nil
        }
    }
}
