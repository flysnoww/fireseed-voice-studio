import SwiftUI
import AVFoundation
import VoiceStudioCore

@main
struct FireseedVoiceStudioApp: App {
    var body: some Scene {
        WindowGroup {
            VoiceStudioRootView()
        }
    }
}

private struct VoiceStudioRootView: View {
    @State private var model: VoiceStudioModel?
    @State private var startupError: String?
    @StateObject private var languagePreference = AppLanguagePreference()
    @StateObject private var appearancePreference = AppAppearancePreference()

    init() {
        do {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-regression") {
                _model = State(initialValue: try Self.regressionModel())
            } else {
                _model = State(initialValue: try VoiceStudioModel())
            }
#else
            _model = State(initialValue: try VoiceStudioModel())
#endif
            _startupError = State(initialValue: nil)
        } catch {
            _model = State(initialValue: nil)
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

#if DEBUG
    /// Isolated synthetic test assets; no user files or fake renderer capabilities.
    @MainActor private static func regressionModel() throws -> VoiceStudioModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UIRegression-\(UUID().uuidString)")
        let store = try AudioFileStore(rootDirectory: root)
        let url = root.appendingPathComponent("synthetic-reference.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 72_000)!
        buffer.frameLength = 72_000
        for index in 0..<72_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 220 / 24_000) * 0.15) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let reference = try store.importAudio(from: url, duration: 3)
        let voice = try store.saveVoice(VoiceAsset(name: "Regression Voice", sourceType: .imported, referenceAudio: reference))
        try VoiceSelectionStore(root: root).select(.saved(voice.id))
        let generated = try store.registerGeneratedAudio(from: url, duration: 3, sourceVoice: .savedVoice(voice.id), language: "en", text: "Synthetic test fixture")
        _ = try store.promoteToPersistent(generated)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let pack = documents.appendingPathComponent("UIOpenVoicePack")
        if FileManager.default.fileExists(atPath: pack.path) {
            let packStore = OpenVoicePackStore(rootDirectory: root.appendingPathComponent("RendererPacks"))
            _ = try packStore.install(from: pack)
        }
        return try VoiceStudioModel(rootDirectory: root)
    }
#endif

    var body: some View {
        Group {
            if let startupError {
                ContentUnavailableView("Voice Studio could not start", systemImage: "waveform", description: Text(startupError))
            } else if let model {
                VoiceStudioHome(model: model)
            } else {
                ContentUnavailableView("Voice Studio could not start", systemImage: "waveform")
            }
        }
        .environmentObject(languagePreference)
        .environmentObject(appearancePreference)
        .environment(\.locale, Locale(identifier: languagePreference.language.localeIdentifier ?? Locale.autoupdatingCurrent.identifier))
    }
}
