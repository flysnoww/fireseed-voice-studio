import AVFoundation
import Combine
import Foundation
import Darwin
import OSLog

private struct QwenPackageManifest: Decodable {
    struct File: Decodable { let path: String; let bytes: Int; let sha256: String }
    let format_version: Int
    let model_revision: String
    let qwen3_tts_cpp_revision: String
    let ggml_revision: String
    let quantization: String
    let files: [File]
}

enum QwenModelPackage {
    static let fileNames = ["qwen3-tts-0.6b-f16.gguf", "qwen3-tts-tokenizer-f16.gguf"]

    static var installedURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Qwen3TTS-0.6B", isDirectory: true)
    }

    static func install(from source: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try validate(source)
        let manager = FileManager.default
        let destination = installedURL
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("Qwen3TTS-0.6B-import-\(UUID().uuidString)", isDirectory: true)
        let backup = parent.appendingPathComponent("Qwen3TTS-0.6B-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging); try? manager.removeItem(at: backup) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        for name in fileNames + ["manifest.json"] {
            try manager.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
        }
        try validate(staging)
        var movedOldPackage = false
        if manager.fileExists(atPath: destination.path) {
            try manager.moveItem(at: destination, to: backup)
            movedOldPackage = true
        }
        do {
            try manager.moveItem(at: staging, to: destination)
        } catch {
            if movedOldPackage { try? manager.moveItem(at: backup, to: destination) }
            throw error
        }
        return destination
    }

    static func validate(_ folder: URL) throws {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(QwenPackageManifest.self, from: data),
              manifest.format_version == 1,
              manifest.model_revision == "dab70521e0956e3db91fb887d36c9a07d21ebc0b",
              manifest.qwen3_tts_cpp_revision == "b3ba14077cf1b3e11b86e5f84aa9184605c89b28",
              manifest.ggml_revision == "3af5f5760e19a96427f5f7a93b79cbdf3d4b265b",
              manifest.quantization == "F16" else {
            throw NSError(domain: "QwenRuntimeSpike", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid model package: manifest.json is missing or unsupported."])
        }
        for name in fileNames {
            guard let record = manifest.files.first(where: { $0.path == name }),
                  record.sha256.count == 64,
                  let values = try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]),
                  values.fileSize == record.bytes else {
                throw NSError(domain: "QwenRuntimeSpike", code: 11,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid model package: missing or truncated \(name)."])
            }
        }
    }
}

struct GenerationResult {
    let url: URL
    let duration: Double
    let elapsed: TimeInterval
    var rtf: Double { elapsed / max(duration, 0.001) }
}

final class QwenRuntime: ObservableObject {
    @Published private(set) var isLoaded = false
    @Published private(set) var hasReference = false
    @Published private(set) var backendName = "Not loaded"
    @Published private(set) var physicalFootprintMB = 0
    private var handle: OpaquePointer?
    private var embedding: [Float]?
    private let logger = Logger(subsystem: "org.fireseed.QwenRuntimeSpike", category: "runtime")
    private(set) var loadMilliseconds = 0
    private(set) var prepareMilliseconds = 0

    private func publishOnMain(_ update: () -> Void) {
        if Thread.isMainThread { update() }
        else { DispatchQueue.main.sync(execute: update) }
    }

    func load(folder: URL?, backend: String) throws {
        let started = ProcessInfo.processInfo.systemUptime
        guard let folder else { throw failure("Model missing: import a model package first.") }
        try QwenModelPackage.validate(folder)
        setenv("QWEN3_TTS_BACKEND", backend == "metal" ? "auto" : backend, 1)
        let next = folder.path.withCString { qwen3_tts_create($0, 4) }
        guard let next else { throw failure("Model load failed: Qwen runtime could not load this model package.") }
        handle = next
        let selectedBackend = String(cString: qwen3_tts_active_backend_name(next))
        if backend == "metal" && !selectedBackend.localizedCaseInsensitiveContains("metal") {
            qwen3_tts_destroy(next)
            handle = nil
            throw failure("Metal unavailable: runtime selected \(selectedBackend).")
        }
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        publishOnMain {
            self.backendName = selectedBackend
            self.loadMilliseconds = elapsed
            self.isLoaded = true
        }
        logger.info("model_load_ms=\(elapsed) backend=\(selectedBackend, privacy: .public)")
        updateFootprint()
    }

    func prepareReference(wav: URL) throws {
        let started = ProcessInfo.processInfo.systemUptime
        guard let handle else { throw failure("Load the model first.") }
        var values = [Float](repeating: 0, count: 4096)
        let count = wav.path.withCString { path in
            values.withUnsafeMutableBufferPointer { buffer in
                qwen3_tts_extract_embedding_file(handle, path, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard count > 0 else { throw runtimeFailure(handle, context: "Reference embedding failed") }
        values.removeSubrange(Int(count)..<values.count)
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        publishOnMain {
            self.embedding = values
            self.hasReference = true
            self.prepareMilliseconds = elapsed
        }
        logger.info("reference_prepare_ms=\(elapsed) embedding_floats=\(count)")
        updateFootprint()
    }

    func generate(text: String) throws -> GenerationResult {
        guard let handle, let embedding else { throw failure("Load the model and prepare reference audio first.") }
        let started = Date()
        var params = Qwen3TtsParams()
        qwen3_tts_default_params(&params)
        params.max_audio_tokens = 240
        let audio: UnsafeMutablePointer<Qwen3TtsAudio>? = embedding.withUnsafeBufferPointer { vector in
            text.withCString { qwen3_tts_synthesize_with_embedding(handle, $0, vector.baseAddress, Int32(vector.count), &params) }
        }
        guard let audio else { throw runtimeFailure(handle, context: "Generation failed") }
        defer { qwen3_tts_free_audio(audio) }
        let samples = Array(UnsafeBufferPointer(start: audio.pointee.samples, count: Int(audio.pointee.n_samples)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("generated-\(UUID().uuidString).wav")
        try writeWav(samples: samples, to: url)
        logger.info("generation_ms=\(Int(Date().timeIntervalSince(started) * 1000)) output_seconds=\(Double(samples.count) / 24000.0)")
        updateFootprint()
        return GenerationResult(url: url, duration: Double(samples.count) / 24_000, elapsed: Date().timeIntervalSince(started))
    }

    func unload() {
        if let handle { qwen3_tts_destroy(handle) }
        handle = nil
        publishOnMain {
            self.embedding = nil
            self.isLoaded = false
            self.hasReference = false
            self.backendName = "Not loaded"
        }
    }

    func logMemoryWarning() { logger.warning("memory_warning_received") }

    private func runtimeFailure(_ handle: OpaquePointer, context: String) -> NSError {
        let detail = String(cString: qwen3_tts_get_error(handle))
        let lower = detail.lowercased()
        let category = lower.contains("memory") || lower.contains("alloc") ? "Out of memory" : context
        return NSError(domain: "QwenRuntimeSpike", code: 2,
                       userInfo: [NSLocalizedDescriptionKey: "\(category): \(detail)"])
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "QwenRuntimeSpike", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func updateFootprint() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let footprint = Int(info.phys_footprint / 1_048_576)
            logger.info("physical_footprint_mb=\(footprint)")
            DispatchQueue.main.async { self.physicalFootprintMB = footprint }
        }
    }

    private func writeWav(samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].assign(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}
