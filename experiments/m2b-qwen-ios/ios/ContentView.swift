import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine

struct ContentView: View {
    @StateObject private var runtime = QwenRuntime()
    @State private var modelFolder: URL?
    @State private var referenceURL: URL?
    @State private var recorder: AVAudioRecorder?
    @State private var recording = false
    @State private var recordStarted: Date?
    @State private var elapsed = 0
    @State private var transcript = ""
    @State private var newText = "Hello, this is a local voice cloning test."
    @State private var backendMode = "metal"
    @State private var status = "Select a local model folder."
    @State private var error: String?
    @State private var showModelPicker = false
    @State private var showAudioPicker = false
    @State private var referencePlayer: AVAudioPlayer?
    @State private var outputPlayer: AVAudioPlayer?
    @State private var outputURL: URL?
    @State private var busy = false
    @State private var memoryWarningCount = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Model") {
                    Button(modelFolder == nil ? "Import model package from Files" : "Model package imported") { showModelPicker = true }
                        .disabled(runtime.isLoaded || busy)
                    Picker("Backend", selection: $backendMode) {
                        Text("Metal").tag("metal")
                        Text("CPU").tag("cpu")
                    }.disabled(runtime.isLoaded || busy)
                    HStack {
                        Button("Load model") {
                            let selectedFolder = modelFolder
                            let selectedBackend = backendMode
                            let modelRuntime = runtime
                            run { try modelRuntime.load(folder: selectedFolder, backend: selectedBackend); return (nil, "Model loaded.") }
                        }
                            .disabled(modelFolder == nil || runtime.isLoaded || busy)
                        Button("Unload") { runtime.unload(); status = "Model unloaded." }
                            .disabled(!runtime.isLoaded || busy)
                    }
                    Text("Backend: \(runtime.backendName)").font(.caption.monospaced())
                    Text("Load: \(runtime.loadMilliseconds) ms · Reference prepare: \(runtime.prepareMilliseconds) ms")
                        .font(.caption.monospaced())
                    Text("Model files are copied to this app's private storage. No network inference.").font(.caption)
                }

                Section("Reference audio") {
                    HStack {
                        Button(recording ? "Stop recording" : "Record") { recording ? stopRecording() : startRecording() }
                            .disabled(busy)
                        Button("Choose WAV / M4A") { showAudioPicker = true }.disabled(recording || busy)
                    }
                    if recording { Label("Recording · \(elapsed)s", systemImage: "record.circle").foregroundStyle(.red) }
                    if let referenceURL {
                        Text(referenceURL.lastPathComponent).font(.caption)
                        Button("Play reference") { play(referenceURL, output: false) }.disabled(recording || busy)
                    }
                    TextField("Reference transcript (diagnostic only; ignored by runtime)", text: $transcript, axis: .vertical)
                        .lineLimit(2...4)
                    Button("Prepare reference embedding") {
                        guard let referenceURL else { return }
                        let modelRuntime = runtime
                        run { try modelRuntime.prepareReference(wav: referenceURL); return (nil, "Reference embedding prepared.") }
                    }.disabled(referenceURL == nil || !runtime.isLoaded || recording || busy)
                }

                Section("Generate") {
                    TextField("New text", text: $newText, axis: .vertical).lineLimit(2...6)
                    Button("Generate local speech") {
                        let modelRuntime = runtime
                        let text = newText
                        run {
                            let result = try modelRuntime.generate(text: text)
                            return (result.url, "Generated \(String(format: "%.2f", result.duration))s in \(Int(result.elapsed * 1000))ms · RTF \(String(format: "%.2f", result.rtf))")
                        }
                    }.disabled(!runtime.isLoaded || !runtime.hasReference || newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recording || busy)
                    if let outputURL {
                        Text(outputURL.lastPathComponent).font(.caption)
                        Button("Play generated audio") { play(outputURL, output: true) }
                    }
                }

                Section("Diagnostics") {
                    Text(status).font(.caption)
                    Text("Physical footprint: \(runtime.physicalFootprintMB) MB · memory warnings: \(memoryWarningCount)")
                        .font(.caption.monospaced())
                    Text("Transcript is diagnostic only; this runtime conditions on a speaker embedding.").font(.caption)
                }
            }
            .navigationTitle("Qwen iOS Spike")
            .onAppear {
                let installed = QwenModelPackage.installedURL
                if FileManager.default.fileExists(atPath: installed.appendingPathComponent("manifest.json").path) {
                    modelFolder = installed
                }
            }
            .fileImporter(isPresented: $showModelPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    busy = true
                    error = nil
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            let installed = try QwenModelPackage.install(from: url)
                            DispatchQueue.main.async { modelFolder = installed; status = "Model package imported to app storage."; busy = false }
                        } catch {
                            DispatchQueue.main.async { self.error = error.localizedDescription; self.busy = false }
                        }
                    }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .fileImporter(isPresented: $showAudioPicker, allowedContentTypes: [.wav, .mpeg4Audio], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        importReference(url)
                    }
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .alert("Spike error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "Unknown error") }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                memoryWarningCount += 1
                runtime.logMemoryWarning()
                status = "iOS memory warning received."
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
                if recording, let start = recordStarted { elapsed = Int(now.timeIntervalSince(start)) }
            }
            .onDisappear { if recording { stopRecording() } }
        }
    }

    private func run(_ operation: @escaping () throws -> (URL?, String?)) {
        guard !busy else { return }
        busy = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try operation()
                DispatchQueue.main.async {
                    if let url = result.0 { self.outputURL = url }
                    if let message = result.1 { self.status = message }
                    self.busy = false
                }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.busy = false }
            }
        }
    }

    private func startRecording() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else { error = "Microphone permission denied."; return }
                do {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("reference-\(UUID().uuidString).wav")
                    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000,
                        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false]
                    let next = try AVAudioRecorder(url: url, settings: settings)
                    try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
                    try AVAudioSession.sharedInstance().setActive(true)
                    next.record()
                    recorder = next; referenceURL = url; recording = true; recordStarted = Date(); elapsed = 0
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func stopRecording() {
        recorder?.stop(); recorder = nil; recording = false; recordStarted = nil
    }

    private func importReference(_ sourceURL: URL) {
        busy = true
        error = nil
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let normalized = try normalizeReference(sourceURL)
                if scoped { sourceURL.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async { referenceURL = normalized; status = "Reference audio decoded and converted to 24 kHz mono WAV."; busy = false }
            } catch {
                if scoped { sourceURL.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async { self.error = "Audio decode failed: \(error.localizedDescription)"; self.busy = false }
            }
        }
    }

    private func normalizeReference(_ sourceURL: URL) throws -> URL {
        let source = try AVAudioFile(forReading: sourceURL)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source.processingFormat, to: targetFormat) else {
            throw NSError(domain: "QwenRuntimeSpike", code: 20, userInfo: [NSLocalizedDescriptionKey: "Unsupported reference audio format."])
        }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("reference-\(UUID().uuidString).wav")
        let output = try AVAudioFile(forWriting: outputURL, settings: targetFormat.settings)
        while true {
            let input = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096)!
            try source.read(into: input)
            if input.frameLength == 0 { break }
            var didProvideInput = false
            var conversionError: NSError?
            let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 8192)!
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                guard !didProvideInput else { inputStatus.pointee = .noDataNow; return nil }
                didProvideInput = true
                inputStatus.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            if converted.frameLength > 0 { try output.write(from: converted) }
            if status == .error { throw NSError(domain: "QwenRuntimeSpike", code: 21, userInfo: [NSLocalizedDescriptionKey: "Audio decoder could not convert the selected file."]) }
        }
        return outputURL
    }

    private func play(_ url: URL, output: Bool) {
        do {
            let player = try AVAudioPlayer(contentsOf: url); player.prepareToPlay(); player.play()
            if output { outputPlayer = player } else { referencePlayer = player }
        } catch { self.error = error.localizedDescription }
    }
}
