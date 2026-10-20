import AuthenticationServices
import Foundation
import SwiftUI
import VoiceStudioCore
import Logto
import LogtoClient
import Security

enum IdentitySignInMethod: String { case apple, google }
enum StudioIdentityError: LocalizedError {
    case configuration, authentication, network, signOut
    var errorDescription: String? {
        switch self {
        case .configuration: return "Sign-in is not configured. Please contact support."
        case .authentication: return "Sign-in could not be completed. Please try again."
        case .network: return "Could not verify your session. Check your connection and sign in again."
        case .signOut: return "Local sign-out completed. The browser session may still be active."
        }
    }
}

struct StudioIdentityConfiguration {
    static let issuer = "https://auth.fireseed.work/oidc"
    static let callback = "com.fireseed.voicestudio://oauth/callback"
    static let signedOut = "com.fireseed.voicestudio://oauth/signed-out"
    let clientID: String
    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) throws {
        guard info["FireseedIdentityIssuer"] as? String == Self.issuer,
              info["FireseedIdentityEndpoint"] as? String == "https://auth.fireseed.work",
              info["FireseedIdentityEnvironment"] as? String == "PRODUCTION",
              info["FireseedIdentityRedirectURI"] as? String == Self.callback,
              info["FireseedIdentityPostLogoutRedirectURI"] as? String == Self.signedOut,
              let id = info["FireseedIdentityClientID"] as? String,
              id == "ghducpbvjml6ovk92e392", id != "2t5wb8w2qqo5d6e8f9aig" else { throw StudioIdentityError.configuration }
        clientID = id
    }
}

struct StudioIdentityUser: Equatable { let owner: AssetOwner; let name: String? }
@MainActor protocol StudioIdentityProvider: AnyObject {
    func restore() async throws -> StudioIdentityUser?
    func signIn(_ method: IdentitySignInMethod) async throws -> StudioIdentityUser
    func signOut() async throws
    func clear() async
}

@MainActor private final class UnauthenticatedFixtureProvider: StudioIdentityProvider {
    func restore() async throws -> StudioIdentityUser? { nil }
    func signIn(_ method: IdentitySignInMethod) async throws -> StudioIdentityUser { throw StudioIdentityError.configuration }
    func signOut() async throws {}
    func clear() async {}
}

/// Only this adapter imports the SDK. It owns discovery, PKCE, callback/state,
/// signature/audience/expiry validation, refresh rotation and Keychain storage.
@MainActor final class StudioLogtoProvider: StudioIdentityProvider {
    private let configuration: StudioIdentityConfiguration?
    private let client: LogtoClient?
    init(configuration: StudioIdentityConfiguration? = try? StudioIdentityConfiguration()) {
        self.configuration = configuration
        if let configuration, let config = try? LogtoConfig(endpoint: "https://auth.fireseed.work",
                appId: configuration.clientID, scopes: [UserScope.email.rawValue, UserScope.profile.rawValue],
                prompt: .login, prefersEphemeralWebBrowserSession: true) {
            let network = URLSessionConfiguration.default
            network.timeoutIntervalForRequest = 30
            network.timeoutIntervalForResource = 90
            client = LogtoClient(useConfig: config, session: URLSession(configuration: network))
        } else { client = nil }
    }
    func restore() async throws -> StudioIdentityUser? {
        guard let client, configuration != nil else { throw StudioIdentityError.configuration }
        guard client.isAuthenticated else { return nil }
        do {
            _ = try await client.getAccessToken(for: nil)
            guard client.oidcConfig?.issuer == StudioIdentityConfiguration.issuer else { throw StudioIdentityError.authentication }
            let info = try await client.fetchUserInfo()
            try secureStoredSession()
            return StudioIdentityUser(owner: try AssetOwner(issuer: StudioIdentityConfiguration.issuer, subject: info.sub), name: info.name)
        } catch {
            await clear()
            throw StudioIdentityError.network
        }
    }
    func signIn(_ method: IdentitySignInMethod) async throws -> StudioIdentityUser {
        guard let client, configuration != nil else { throw StudioIdentityError.configuration }
        do {
            // Native app entry -> system browser -> existing universal social connector.
            let connector = method == .apple ? "fo8oqzueaxapk6iw625lf" : "e8kbgsw287oxnop4gr4dt"
            try await client.signInWithBrowser(redirectUri: StudioIdentityConfiguration.callback,
                directSignIn: .init(method: .social, target: connector))
            try Task.checkCancellation()
            let claims = try client.getIdTokenClaims()
            guard claims.iss == StudioIdentityConfiguration.issuer,
                  client.oidcConfig?.issuer == StudioIdentityConfiguration.issuer else { throw StudioIdentityError.authentication }
            try secureStoredSession()
            return StudioIdentityUser(owner: try AssetOwner(issuer: claims.iss, subject: claims.sub), name: claims.name)
        } catch {
            await clear()
            let cause = ((error as? LogtoClientErrors.SignIn)?.innerError ?? error) as NSError
            if error is CancellationError || (cause.domain == ASWebAuthenticationSessionError.errorDomain && cause.code == ASWebAuthenticationSessionError.Code.canceledLogin.rawValue) { throw CancellationError() }
            if cause.domain == NSURLErrorDomain { throw StudioIdentityError.network }
            throw StudioIdentityError.authentication
        }
    }
    func signOut() async throws {
        guard let client else { return }
        let result = await client.signOut(postLogoutRedirectUri: StudioIdentityConfiguration.signedOut)
        if result != nil { throw StudioIdentityError.signOut }
    }
    func clear() async { _ = await client?.clearCredentials() }
    private func secureStoredSession() throws {
        // The pinned SDK stores only these two items in this app's default access
        // group (no cross-app Keychain group). Verify writes and restrict backup/lock access.
        for account in ["id_token", "refresh_token"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "io.logto.client", kSecAttrAccount as String: account]
            guard SecItemUpdate(query as CFDictionary,
                [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary) == errSecSuccess else {
                throw StudioIdentityError.authentication
            }
        }
    }
}

/// Serialize SDK operations. An invalidated request can neither reactivate an old
/// owner nor write tokens over a new login. Sign-out hides data synchronously.
@MainActor final class StudioIdentitySession: ObservableObject {
    @Published private(set) var user: StudioIdentityUser?
    @Published private(set) var busy = false
    @Published private(set) var restoring = true
    @Published var message: String?
    var changed: ((StudioIdentityUser?) -> Void)?
    private let provider: any StudioIdentityProvider
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    init(provider: any StudioIdentityProvider) { self.provider = provider }
    func restore() async {
        guard operation == nil, restoring else { return }
        begin { try await self.provider.restore() }
        await operation?.value
    }
    func signIn(_ method: IdentitySignInMethod) {
        guard !busy, user == nil, !restoring else { return }
        begin { try await self.provider.signIn(method) }
    }
    func revalidate() {
        guard !busy, !restoring, let expected = user?.owner else { return }
        begin {
            let refreshed = try await self.provider.restore()
            guard refreshed?.owner == expected else { throw StudioIdentityError.authentication }
            return refreshed
        }
    }
    private func begin(_ action: @escaping @MainActor () async throws -> StudioIdentityUser?) {
        guard !busy else { return }
        busy = true; message = nil
        let token = UUID(); generation = token
        operation = Task {
            do {
                let user = try await action()
                guard generation == token, !Task.isCancelled else { await provider.clear(); return }
                self.user = user; changed?(user)
            } catch {
                guard generation == token else { return }
                await provider.clear()
                guard generation == token else { return }
                if user != nil { user = nil; changed?(nil) }
                if !(error is CancellationError) { message = (error as? StudioIdentityError)?.localizedDescription ?? StudioIdentityError.authentication.localizedDescription }
            }
            guard generation == token else { return }
            busy = false; restoring = false; operation = nil
        }
    }
    func signOut() {
        let oldOperation = operation
        let token = UUID(); generation = token
        oldOperation?.cancel()
        user = nil; changed?(nil); message = nil; restoring = false; busy = true
        operation = Task {
            await oldOperation?.value
            do { try await provider.signOut() } catch { message = StudioIdentityError.signOut.localizedDescription }
            await provider.clear()
            guard generation == token else { return }
            busy = false; operation = nil
        }
    }
}

@MainActor final class StudioAccountController: ObservableObject {
    @Published private(set) var model: VoiceStudioModel?
    @Published var startupError: String?
    @Published var showAccount = false
    @Published var revision = UUID()
    @Published var generationText = ""
    @Published private(set) var legacy: LegacyAssetInventory?
    @Published private(set) var appearance = AppAppearancePreference(backgroundKey: "guest.noBackground")
    let session: StudioIdentitySession
    private let workspace: IdentityWorkspace
    private let base: URL
    private var owner: AssetOwner?
    private var pendingClaimDrafts: [String: TemporaryStudioDraft] = [:]
    let fixture: Bool
    init(startupError: String) {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceStudioUnavailable-" + UUID().uuidString)
        workspace = IdentityWorkspace(root: base)
        session = StudioIdentitySession(provider: UnauthenticatedFixtureProvider())
        fixture = true
        self.startupError = startupError
    }
    init(fixtureModel: VoiceStudioModel? = nil, base: URL? = nil, provider: (any StudioIdentityProvider)? = nil) {
        self.base = base ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceStudio")
        workspace = IdentityWorkspace(root: self.base)
        let selectedProvider: any StudioIdentityProvider
        if let provider { selectedProvider = provider }
        else if fixtureModel != nil { selectedProvider = UnauthenticatedFixtureProvider() }
        else { selectedProvider = StudioLogtoProvider() }
        session = StudioIdentitySession(provider: selectedProvider)
        fixture = fixtureModel != nil
        if let fixtureModel {
            model = fixtureModel
            appearance = AppAppearancePreference(defaults: UserDefaults(suiteName: "com.fireseed.voicestudio.ui-regression")!, appearanceDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("VoiceStudioUIAppearance"))
            return
        }
        session.changed = { [weak self] user in self?.activate(user?.owner) }
        activate(nil)
    }
    private func activate(_ newOwner: AssetOwner?) {
        if owner == newOwner, model != nil { return }
        let previous = model
        let mayTransferGuestDraft = owner == nil && newOwner != nil
        previous?.applicationDidEnterBackground()
        model = nil; revision = UUID()
        if !mayTransferGuestDraft { generationText = "" }
        do {
            let root: URL
            if let newOwner { root = try workspace.dataRoot(for: newOwner) }
            else { root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceStudioGuest-" + UUID().uuidString) }
            let scope = newOwner?.namespace ?? UUID().uuidString
            let defaults = UserDefaults(suiteName: "com.fireseed.voicestudio.identity." + scope)!
            let background = root.appendingPathComponent("Appearance/background.jpg")
            if FileManager.default.fileExists(atPath: background.path) { defaults.set(background.path, forKey: "appBackgroundImagePath") }
            appearance = AppAppearancePreference(defaults: defaults, appearanceDirectory: root.appendingPathComponent("Appearance"))
            let next = try VoiceStudioModel(rootDirectory: root, privatePersistenceAllowed: newOwner != nil, sharedResourcesRoot: base,
                diagnostics: VoiceStudioDiagnostics(defaults: defaults, includeDeviceCrashReports: false))
            if mayTransferGuestDraft { try previous?.copyTemporaryDraft(to: next) }
            previous?.invalidateIdentityContext()
            next.requestIdentity = { [weak self] in self?.showAccount = true }
            model = next; owner = newOwner; showAccount = false
            legacy = try workspace.legacyNeedsClaim() ? workspace.legacyInventory() : nil
        } catch {
            previous?.invalidateIdentityContext()
            startupError = "Could not safely open your audio library. Original files have been preserved."
        }
    }
    func claimLegacy() {
        guard let owner, session.user?.owner == owner, !session.busy else { return }
        let text = generationText
        let key = owner.namespace
        do {
            if pendingClaimDrafts[key] == nil { pendingClaimDrafts[key] = try model?.temporaryDraft() }
            model?.invalidateIdentityContext(); model = nil
            _ = try workspace.claimLegacy(for: owner)
            activate(owner)
            if let draft = pendingClaimDrafts[key] { try model?.restoreTemporaryDraft(draft) }
            pendingClaimDrafts.removeValue(forKey: key); generationText = text
        } catch {
            activate(owner); generationText = text
            session.message = "Could not complete the legacy claim. Original files, backup and pending draft have been preserved."
        }
    }
}

struct StudioAccountView: View {
    @EnvironmentObject var account: StudioAccountController
    @ObservedObject var session: StudioIdentitySession
    @State private var confirmClaim = false
    var body: some View {
        VStack(spacing: 16) {
            if let user = session.user {
                Label(user.name ?? "Signed in to Fireseed", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
                if let inventory = account.legacy {
                    Text("This device has \(inventory.voices) legacy voices and \(inventory.audio) audio records. They are not assigned to an account.").font(.footnote)
                    Button("Claim legacy sounds for this account") { confirmClaim = true }.accessibilityIdentifier("claimLegacyButton")
                }
                Button("Sign out / switch account", role: .destructive) { session.signOut() }.accessibilityIdentifier("identitySignOut")
            } else {
                Text("Sign in to save private voices and audio.").multilineTextAlignment(.center)
                StudioAppleSignInButton { session.signIn(.apple) }.frame(height: 44).accessibilityIdentifier("identityApple")
                Button("Continue with Google") { session.signIn(.google) }.buttonStyle(.bordered).accessibilityIdentifier("identityGoogle")
            }
            if session.busy { ProgressView(session.restoring ? "Restoring session…" : "Completing authentication…") }
            if let message = session.message { Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("identityMessage") }
            Text("Your sounds stay in Voice Studio. Signing out does not delete them.").font(.footnote).foregroundStyle(.secondary)
        }.padding().disabled(session.busy)
            .confirmationDialog("Assign this device's legacy sounds to the currently signed-in account?", isPresented: $confirmClaim, titleVisibility: .visible) {
                Button("Back up and claim sounds") { account.claimLegacy() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Original audio and asset IDs are preserved. Other accounts will not inherit this library.") }
    }
}

private struct StudioAppleSignInButton: UIViewRepresentable {
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: .black)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        button.accessibilityIdentifier = "identityApple"
        return button
    }
    func updateUIView(_ view: ASAuthorizationAppleIDButton, context: Context) { context.coordinator.action = action }
}
