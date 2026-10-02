import AVFoundation
import Accelerate
import CoreML
import Foundation
import VoiceStudioCore

enum OpenVoiceRuntimeError: Error, Equatable {
    case invalidAudio
    case invalidModelContract
    case predictionFailed
    case busy
    case audioTooLong
}

enum OpenVoiceRuntimeMetrics {
    static func realTimeFactor(elapsedMilliseconds: Int, audioDuration: TimeInterval) -> Double? {
        guard elapsedMilliseconds >= 0, audioDuration.isFinite, audioDuration > 0 else { return nil }
        return Double(elapsedMilliseconds) / 1_000 / audioDuration
    }
}

enum OpenVoiceModelContract {
    static let encoderInputs: Set<String> = ["spectrogram"]
    static let encoderOutputs: Set<String> = ["speaker_embedding"]
    static let converterInputs: Set<String> = ["spectrogram", "spec_lengths", "source_speaker", "target_speaker"]
    static let converterOutputs: Set<String> = ["audio"]

    static func matches(inputs: Set<String>, outputs: Set<String>, converter: Bool) -> Bool {
        inputs == (converter ? converterInputs : encoderInputs) &&
            outputs == (converter ? converterOutputs : encoderOutputs)
    }
}

/// Loads one Core ML component at a time. Compiled packages and speaker vectors
/// are disposable cache data; source/reference audio stays in AudioFileStore.
actor OpenVoiceCoreMLConverter: VoiceConverterProvider {
    private var busy = false
    private var lastTimings = VoiceConverterTimings()
    func timings() -> VoiceConverterTimings? { lastTimings }
    private static let sampleRate = 22_050.0
    private static let fftSize = 1_024
    private static let hopLength = 256
    private let fileManager = FileManager.default

    nonisolated let capabilities = CapabilityProfile(
        support: [.voiceConversion: .supported],
        languages: ["en", "zh"])

    func validateModels(packDirectory: URL, cacheDirectory: URL) async throws {
        guard !busy else { throw OpenVoiceRuntimeError.busy }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        try await validateEncoder(packDirectory: packDirectory, cacheDirectory: cacheDirectory)
        try await validateConverter(packDirectory: packDirectory, cacheDirectory: cacheDirectory)
    }

    private func validateEncoder(packDirectory: URL, cacheDirectory: URL) async throws {
        let encoder = try await loadModel(named: "OpenVoice_SpeakerEncoder", packDirectory: packDirectory,
                                          cacheDirectory: cacheDirectory)
        guard OpenVoiceModelContract.matches(
            inputs: Set(encoder.modelDescription.inputDescriptionsByName.keys),
            outputs: Set(encoder.modelDescription.outputDescriptionsByName.keys), converter: false) else {
            throw OpenVoiceRuntimeError.invalidModelContract
        }
    }

    func prepareReference(referenceURL: URL, voiceID: UUID, referenceAudioID: UUID,
                          packDirectory: URL, cacheDirectory: URL) async throws {
        guard !busy else { throw OpenVoiceRuntimeError.busy }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        let cache = OpenVoiceSpeakerEmbeddingCache(rootDirectory: cacheDirectory.appendingPathComponent("Embeddings", isDirectory: true))
        if cache.load(voiceID: voiceID, referenceAudioID: referenceAudioID,
                      packRevision: OpenVoicePackStore.converterRevision) != nil { return }
        let embedding = try await extractEmbedding(audioURL: referenceURL, packDirectory: packDirectory,
                                                   cacheDirectory: cacheDirectory)
        try Task.checkCancellation()
        try cache.store(embedding, voiceID: voiceID, referenceAudioID: referenceAudioID,
                        packRevision: OpenVoicePackStore.converterRevision)
    }

    func convert(sourceURL: URL, targetReferenceURL: URL, targetVoiceID: UUID,
                 targetReferenceID: UUID, packDirectory: URL, cacheDirectory: URL) async throws -> URL {
        guard !busy else { throw OpenVoiceRuntimeError.busy }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        lastTimings = VoiceConverterTimings()
        let cache = OpenVoiceSpeakerEmbeddingCache(rootDirectory: cacheDirectory.appendingPathComponent("Embeddings", isDirectory: true))
        let targetEmbedding: [Float]
        if let cached = cache.load(voiceID: targetVoiceID, referenceAudioID: targetReferenceID,
                                   packRevision: OpenVoicePackStore.converterRevision) {
            lastTimings.embeddingCacheHit = true
            targetEmbedding = cached
        } else {
            targetEmbedding = try await extractEmbedding(audioURL: targetReferenceURL,
                                                         packDirectory: packDirectory,
                                                         cacheDirectory: cacheDirectory)
            try cache.store(targetEmbedding, voiceID: targetVoiceID, referenceAudioID: targetReferenceID,
                            packRevision: OpenVoicePackStore.converterRevision)
        }
        try Task.checkCancellation()
        let sourceEmbedding = try await extractEmbedding(audioURL: sourceURL,
                                                        packDirectory: packDirectory,
                                                        cacheDirectory: cacheDirectory)
        guard sourceEmbedding.count == 256, targetEmbedding.count == 256 else {
            throw OpenVoiceRuntimeError.predictionFailed
        }

        try Task.checkCancellation()
        let converter = try await loadModel(named: "OpenVoice_VoiceConverter", packDirectory: packDirectory,
                                            cacheDirectory: cacheDirectory)
        guard OpenVoiceModelContract.matches(
            inputs: Set(converter.modelDescription.inputDescriptionsByName.keys),
            outputs: Set(converter.modelDescription.outputDescriptionsByName.keys), converter: true) else {
            throw OpenVoiceRuntimeError.invalidModelContract
        }
        let spectrogram = try stft(samples: loadMonoSamples(sourceURL))
        let frames = spectrogram.count / 513
        let spec = try multiArray(shape: [1, 513, frames], values: spectrogram)
        let lengths = try MLMultiArray(shape: [1], dataType: .float32)
        lengths[0] = NSNumber(value: frames)
        let source = try multiArray(shape: [1, 256, 1], values: sourceEmbedding)
        let target = try multiArray(shape: [1, 256, 1], values: targetEmbedding)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "spectrogram": MLFeatureValue(multiArray: spec),
            "spec_lengths": MLFeatureValue(multiArray: lengths),
            "source_speaker": MLFeatureValue(multiArray: source),
            "target_speaker": MLFeatureValue(multiArray: target),
        ])
        let conversionStarted = ProcessInfo.processInfo.systemUptime
        guard let output = try await converter.prediction(from: input)
            .featureValue(for: "audio")?.multiArrayValue else { throw OpenVoiceRuntimeError.predictionFailed }
        try Task.checkCancellation()
        lastTimings.conversionMilliseconds = Int((ProcessInfo.processInfo.systemUptime - conversionStarted) * 1000)
        return try writeWAV((0..<output.count).map { output[$0].floatValue })
    }

    private func validateConverter(packDirectory: URL, cacheDirectory: URL) async throws {
        try Task.checkCancellation()
        let converter = try await loadModel(named: "OpenVoice_VoiceConverter", packDirectory: packDirectory,
                                            cacheDirectory: cacheDirectory)
        guard OpenVoiceModelContract.matches(
            inputs: Set(converter.modelDescription.inputDescriptionsByName.keys),
            outputs: Set(converter.modelDescription.outputDescriptionsByName.keys), converter: true) else {
            throw OpenVoiceRuntimeError.invalidModelContract
        }
    }

    private func loadModel(named name: String, packDirectory: URL, cacheDirectory: URL) async throws -> MLModel {
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        defer { lastTimings.loadMilliseconds += Int((ProcessInfo.processInfo.systemUptime - started) * 1000) }
        let packageURL = packDirectory.appendingPathComponent("\(name).mlpackage", isDirectory: true)
        let compiledDirectory = cacheDirectory.appendingPathComponent("Compiled", isDirectory: true)
        try fileManager.createDirectory(at: compiledDirectory, withIntermediateDirectories: true)
        let compiledURL = compiledDirectory.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        if !fileManager.fileExists(atPath: compiledURL.path) {
            let temporary = try await MLModel.compileModel(at: packageURL)
            defer { try? fileManager.removeItem(at: temporary) }
            try Task.checkCancellation()
            if !fileManager.fileExists(atPath: compiledURL.path) { try fileManager.copyItem(at: temporary, to: compiledURL) }
        }
        try Task.checkCancellation()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        return try MLModel(contentsOf: compiledURL, configuration: configuration)
    }

    private func extractEmbedding(audioURL: URL, packDirectory: URL, cacheDirectory: URL) async throws -> [Float] {
        let started = ProcessInfo.processInfo.systemUptime
        let previousLoad = lastTimings.loadMilliseconds
        defer {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            lastTimings.embeddingMilliseconds += max(0, elapsed - (lastTimings.loadMilliseconds - previousLoad))
        }
        let samples = try loadMonoSamples(audioURL)
        let spectrum = try stft(samples: samples)
        let frames = spectrum.count / 513
        var transposed = [Float](repeating: 0, count: spectrum.count)
        for frequency in 0..<513 {
            for frame in 0..<frames { transposed[frame * 513 + frequency] = spectrum[frequency * frames + frame] }
        }
        let model = try await loadModel(named: "OpenVoice_SpeakerEncoder", packDirectory: packDirectory,
                                        cacheDirectory: cacheDirectory)
        let inputArray = try multiArray(shape: [1, frames, 513], values: transposed)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "spectrogram": MLFeatureValue(multiArray: inputArray),
        ])
        guard let output = try await model.prediction(from: input)
            .featureValue(for: "speaker_embedding")?.multiArrayValue else {
            throw OpenVoiceRuntimeError.predictionFailed
        }
        try Task.checkCancellation()
        let embedding = (0..<output.count).map { output[$0].floatValue }
        guard embedding.count == 256, embedding.allSatisfy(\.isFinite) else {
            throw OpenVoiceRuntimeError.predictionFailed
        }
        return embedding
    }

    private func multiArray(shape: [Int], values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        guard array.count == values.count else { throw OpenVoiceRuntimeError.predictionFailed }
        for index in values.indices { array[index] = NSNumber(value: values[index]) }
        return array
    }

    private func loadMonoSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.length <= AVAudioFramePosition(AVAudioFrameCount.max) else { throw OpenVoiceRuntimeError.invalidAudio }
        let inputFormat = file.processingFormat
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
              inputFormat.sampleRate <= 192_000, inputFormat.channelCount > 0,
              inputFormat.channelCount <= 2 else { throw OpenVoiceRuntimeError.invalidAudio }
        // Bound PCM and Core ML activation memory before allocating; never truncate silently.
        guard Double(file.length) / inputFormat.sampleRate <= 30 else { throw OpenVoiceRuntimeError.audioTooLong }
        try Task.checkCancellation()
        let frameCount = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw OpenVoiceRuntimeError.invalidAudio
        }
        try file.read(into: inputBuffer)
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw OpenVoiceRuntimeError.invalidAudio
        }
        let capacity = AVAudioFrameCount(ceil(Double(frameCount) * Self.sampleRate / inputFormat.sampleRate)) + 1_024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw OpenVoiceRuntimeError.invalidAudio
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError, withInputFrom: { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        })
        guard conversionError == nil, outputBuffer.frameLength > 0,
              let channel = outputBuffer.floatChannelData?.pointee else { throw OpenVoiceRuntimeError.invalidAudio }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }

    /// Magnitude STFT layout matches the pinned Core ML conversion contract.
    func stft(samples: [Float]) throws -> [Float] {
        guard samples.count >= Self.hopLength, samples.allSatisfy(\.isFinite) else { throw OpenVoiceRuntimeError.invalidAudio }
        let padding = (Self.fftSize - Self.hopLength) / 2
        var padded = [Float](repeating: 0, count: samples.count + 2 * padding)
        for index in 0..<padding {
            padded[padding - index - 1] = samples[min(index + 1, samples.count - 1)]
            padded[padding + samples.count + index] = samples[max(samples.count - 2 - index, 0)]
        }
        padded.replaceSubrange(padding..<(padding + samples.count), with: samples)
        let bins = Self.fftSize / 2 + 1
        let frames = (padded.count - Self.fftSize) / Self.hopLength + 1
        var window = [Float](repeating: 0, count: Self.fftSize)
        for index in window.indices {
            window[index] = 0.5 * (1 - cos(2 * .pi * Float(index) / Float(Self.fftSize - 1)))
        }
        let log2Size = vDSP_Length(log2(Float(Self.fftSize)))
        guard let setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else {
            throw OpenVoiceRuntimeError.invalidAudio
        }
        defer { vDSP_destroy_fftsetup(setup) }
        var result = [Float](repeating: 0, count: bins * frames)
        let half = Self.fftSize / 2
        for frame in 0..<frames {
            try Task.checkCancellation()
            let start = frame * Self.hopLength
            let frameSamples = Array(padded[start..<(start + Self.fftSize)])
            var windowed = [Float](repeating: 0, count: Self.fftSize)
            vDSP_vmul(frameSamples, 1, window, 1, &windowed, 1, vDSP_Length(Self.fftSize))
            var real = [Float](repeating: 0, count: half)
            var imaginary = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                    windowed.withUnsafeBufferPointer { values in
                        values.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                    result[frame] = sqrt(realBuffer[0] * realBuffer[0] + 1e-6)
                    result[(bins - 1) * frames + frame] = sqrt(imaginaryBuffer[0] * imaginaryBuffer[0] + 1e-6)
                    for bin in 1..<(bins - 1) {
                        let re = realBuffer[bin] / 2
                        let im = imaginaryBuffer[bin] / 2
                        result[bin * frames + frame] = sqrt(re * re + im * im + 1e-6)
                    }
                }
            }
        }
        return result
    }

    private func writeWAV(_ samples: [Float]) throws -> URL {
        guard !samples.isEmpty, samples.count <= 22_050 * 31, samples.allSatisfy(\.isFinite),
              let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw OpenVoiceRuntimeError.invalidAudio
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("openvoice-\(UUID().uuidString).wav")
        var succeeded = false
        defer { if !succeeded { try? fileManager.removeItem(at: url) } }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?.pointee else { throw OpenVoiceRuntimeError.invalidAudio }
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        let scale: Float = peak > 1 ? 0.95 / peak : 1
        for index in samples.indices { channel[index] = min(1, max(-1, samples[index] * scale)) }
        try Task.checkCancellation()
        try file.write(from: buffer)
        succeeded = true
        return url
    }
}
