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
    @StateObject private var account: StudioAccountController
    @StateObject private var languagePreference = AppLanguagePreference()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-identity") {
                let controller = try Self.identityRegressionController()
                _account = StateObject(wrappedValue: controller)
            } else if ProcessInfo.processInfo.arguments.contains("-ui-regression") {
                let fixtureModel = try Self.regressionModel()
                _account = StateObject(wrappedValue: StudioAccountController(fixtureModel: fixtureModel))
            } else if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                let controller = StudioAccountController(base: FileManager.default.temporaryDirectory.appendingPathComponent("XCTestHost-" + UUID().uuidString), provider: UIIdentityProvider())
                _account = StateObject(wrappedValue: controller)
            } else {
                _account = StateObject(wrappedValue: StudioAccountController())
            }
#else
            _account = StateObject(wrappedValue: StudioAccountController())
#endif
        } catch {
            _account = StateObject(wrappedValue: StudioAccountController(startupError: "Voice Studio could not safely initialize. Original files have been preserved."))
        }
    }

#if DEBUG
    @MainActor private static func identityRegressionController() throws -> StudioAccountController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IdentityUI-" + UUID().uuidString)
        let store = try AudioFileStore(rootDirectory: root)
        let source = root.appendingPathComponent("synthetic.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400)!; buffer.frameLength = 2400
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)
        let audio = try store.importAudio(from: source, duration: 0.1)
        _ = try store.saveVoice(VoiceAsset(name: "Legacy Fixture Voice", sourceType: .record, referenceAudio: audio))
        return StudioAccountController(base: root, provider: UIIdentityProvider())
    }
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
        return try VoiceStudioModel(rootDirectory: root, privatePersistenceAllowed: true)
    }
#endif

    var body: some View {
        Group {
            if let startupError = account.startupError {
                ContentUnavailableView("Voice Studio could not start", systemImage: "waveform", description: Text(startupError))
            } else if let model = account.model {
                VoiceStudioHome(model: model, generationText: $account.generationText).id(account.revision)
            } else {
                ContentUnavailableView("Voice Studio could not start", systemImage: "waveform")
            }
        }
        .environmentObject(languagePreference)
        .environmentObject(account)
        .environmentObject(account.session)
        .environmentObject(account.appearance)
        .environment(\.locale, Locale(identifier: languagePreference.language.localeIdentifier ?? Locale.autoupdatingCurrent.identifier))
        .task { if !account.fixture { await account.session.restore() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active, !account.fixture { account.session.revalidate() } }
        .sheet(isPresented: $account.showAccount) {
            StudioAccountView(session: account.session).environmentObject(account).presentationDetents([.medium, .large])
        }
    }
}

#if DEBUG
/// Explicit, isolated automation injection; never selected by Release or config failure.
@MainActor private final class UIIdentityProvider: StudioIdentityProvider {
    func restore() async throws -> StudioIdentityUser? { nil }
    func signIn(_ method: IdentitySignInMethod) async throws -> StudioIdentityUser {
        StudioIdentityUser(owner: try AssetOwner(issuer: StudioIdentityConfiguration.issuer, subject: "ui-fixture-" + method.rawValue), name: "UI Fixture " + method.rawValue)
    }
    func signOut() async throws {}
    func clear() async {}
}
#endif
