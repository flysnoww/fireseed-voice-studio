import SwiftUI

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

    init() {
        do {
            _model = State(initialValue: try VoiceStudioModel())
            _startupError = State(initialValue: nil)
        } catch {
            _model = State(initialValue: nil)
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

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
        .environment(\.locale, Locale(identifier: languagePreference.language.localeIdentifier ?? Locale.autoupdatingCurrent.identifier))
    }
}
