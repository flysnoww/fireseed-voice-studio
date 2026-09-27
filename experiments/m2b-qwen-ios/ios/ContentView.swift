import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine

struct ContentView: View {
    @StateObject private var runtime = QwenRuntime()
    @State private var modelFolder: URL?
    @State private var referenceURL: URL?
    @State private var scopedReferenceURL: URL?
    @State private var recorder: AVAudioRecorder?
    @State private var recording = false
    @State private var recordStarted: Date?
    @State private var elapsed = 0
    @State private var transcript = ""
    @State private var newText = "Hello, this is a local voice cloning test."
    @State private var backendMode = "auto"
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
                    Button(modelFolder?.lastPathComponent ?? "Choose on-device model folder") { showModelPicker = true }
                    Picker("Backend", selection: $backendMode) {
                        Text("Auto (Metal if available)").tag("auto")
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
                    Text("Model files stay on this device. No network inference.").font(.caption)
                }

                Section("Reference audio") {
                    HStack {
                        Button(recording ? "Stop recording" : "Record") { recording ? stopRecording() : startRecording() }
                            .disabled(busy)
                        Button("Choose WAV") { showAudioPicker = true }.disabled(recording || busy)
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
            .fileImporter(isPresented: $showModelPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    modelFolder = url
                    runtime.holdSecurityScope(url)
                    status = "Model folder selected."
                case .failure(let failure): error = failure.localizedDescription
                }
            }
            .fileImporter(isPresented: $showAudioPicker, allowedContentTypes: [.wav], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        if let scopedReferenceURL { scopedReferenceURL.stopAccessingSecurityScopedResource() }
                        _ = url.startAccessingSecurityScopedResource()
                        scopedReferenceURL = url
                        referenceURL = url
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
                    if let scopedReferenceURL { scopedReferenceURL.stopAccessingSecurityScopedResource() }
                    scopedReferenceURL = nil
                    recorder = next; referenceURL = url; recording = true; recordStarted = Date(); elapsed = 0
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func stopRecording() {
        recorder?.stop(); recorder = nil; recording = false; recordStarted = nil
    }

    private func play(_ url: URL, output: Bool) {
        do {
            let player = try AVAudioPlayer(contentsOf: url); player.prepareToPlay(); player.play()
            if output { outputPlayer = player } else { referencePlayer = player }
        } catch { error = error.localizedDescription }
    }
}
