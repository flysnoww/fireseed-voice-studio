import AVFoundation
import Combine
import Foundation
import Darwin
import OSLog

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
    private var securityScopedFolder: URL?
    private let logger = Logger(subsystem: "org.fireseed.QwenRuntimeSpike", category: "runtime")
    private(set) var loadMilliseconds = 0
    private(set) var prepareMilliseconds = 0

    func holdSecurityScope(_ url: URL) {
        if let securityScopedFolder { securityScopedFolder.stopAccessingSecurityScopedResource() }
        _ = url.startAccessingSecurityScopedResource()
        securityScopedFolder = url
    }

    private func publishOnMain(_ update: () -> Void) {
        if Thread.isMainThread { update() }
        else { DispatchQueue.main.sync(execute: update) }
    }

    func load(folder: URL?, backend: String) throws {
        let started = ProcessInfo.processInfo.systemUptime
        guard let folder else { throw failure("Select a local model folder.") }
        setenv("QWEN3_TTS_BACKEND", backend, 1)
        let main = folder.appendingPathComponent("qwen3-tts-0.6b-f16.gguf")
        let tokenizer = folder.appendingPathComponent("qwen3-tts-tokenizer-f16.gguf")
        guard FileManager.default.fileExists(atPath: main.path), FileManager.default.fileExists(atPath: tokenizer.path) else {
            throw failure("The selected folder does not contain both converted GGUF files.")
        }
        let next = folder.path.withCString { qwen3_tts_create($0, 4) }
        guard let next else { throw failure("qwen3_tts_create failed while loading the model directory.") }
        handle = next
        let selectedBackend = String(cString: qwen3_tts_active_backend_name(next))
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
        guard count > 0 else { throw runtimeFailure(handle) }
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
        guard let audio else { throw runtimeFailure(handle) }
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
        if let securityScopedFolder { securityScopedFolder.stopAccessingSecurityScopedResource() }
        securityScopedFolder = nil
    }

    func logMemoryWarning() { logger.warning("memory_warning_received") }

    private func runtimeFailure(_ handle: OpaquePointer) -> NSError {
        NSError(domain: "QwenRuntimeSpike", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: qwen3_tts_get_error(handle))])
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
