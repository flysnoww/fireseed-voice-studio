import Foundation
import XCTest
@testable import VoiceStudioCore

final class IdentityWorkspaceTests: XCTestCase {
    private struct Selection: Codable { let current: VoiceSelection; var systems: [String: VoiceProfile] = [:] }
    private var root: URL!
    private var a: AssetOwner { try! AssetOwner(issuer: "https://auth.fireseed.work/oidc", subject: "account-a") }
    private var b: AssetOwner { try! AssetOwner(issuer: "https://auth.fireseed.work/oidc", subject: "account-b") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func seed(_ store: AudioFileStore) throws -> VoiceAsset {
        let source = root.appendingPathComponent("source.wav")
        try Data([1,2,3,4,5]).write(to: source)
        let audio = try store.importAudio(from: source, duration: 1)
        return try store.saveVoice(VoiceAsset(name: "Private reference", sourceType: .record, referenceAudio: audio))
    }
    func testIssuerAndSubjectBothDefineNamespaceAndUnsafeOwnerIsRejected() throws {
        XCTAssertNotEqual(a.namespace, b.namespace)
        XCTAssertNotEqual(a.namespace, try AssetOwner(issuer: "https://other.example/oidc", subject: a.subject).namespace)
        XCTAssertThrowsError(try AssetOwner(issuer: "https://auth.fireseed.work/oidc?alias=yes", subject: "a"))
        XCTAssertThrowsError(try AssetOwner(issuer: "https://auth.fireseed.work/oidc", subject: ""))
    }
    func testTwoAccountsCannotReadPlayModifyOrDeleteEachOthersAudio() throws {
        let workspace = IdentityWorkspace(root: root)
        let storeA = try AudioFileStore(rootDirectory: workspace.dataRoot(for: a))
        let voice = try seed(storeA)
        let storeB = try AudioFileStore(rootDirectory: workspace.dataRoot(for: b))
        XCTAssertTrue(storeB.savedVoices().isEmpty)
        XCTAssertTrue(storeB.savedAudioAssets().isEmpty)
        XCTAssertThrowsError(try storeB.managedURL(for: voice.referenceAudio))
        XCTAssertThrowsError(try storeB.renameVoice(id: voice.id, name: "Hijacked"))
        XCTAssertThrowsError(try storeB.deleteVoice(id: voice.id))
        XCTAssertEqual(try AudioFileStore(rootDirectory: workspace.dataRoot(for: a)).savedVoices().first?.id, voice.id)
    }
    func testGuestCannotPersistButItsTemporaryDraftRemainsAfterRejectedSave() throws {
        let guest = try AudioFileStore(rootDirectory: root, allowsPersistentWrites: false)
        let source = root.appendingPathComponent("source.wav"); try Data([1,2]).write(to: source)
        let draft = try guest.importAudio(from: source, duration: 1)
        XCTAssertThrowsError(try guest.promoteToPersistent(draft))
        XCTAssertEqual(try Data(contentsOf: guest.managedURL(for: draft)), Data([1,2]))
        XCTAssertTrue(guest.savedAudioAssets().isEmpty)
    }
    func testRevokedContextBlocksLateTasksAndFileAccess() throws {
        let store = try AudioFileStore(rootDirectory: root)
        let voice = try seed(store)
        store.invalidateAccess()
        XCTAssertThrowsError(try store.managedURL(for: voice.referenceAudio))
        XCTAssertThrowsError(try store.deleteVoice(id: voice.id))
        XCTAssertThrowsError(try store.saveVoice(voice))
        XCTAssertTrue(store.savedVoices().isEmpty)
        XCTAssertEqual(try AudioFileStore(rootDirectory: root).savedVoices().count, 1)
    }
    func testLegacyIsNotAutomaticallyAdoptedAndExplicitClaimPreservesIDsFilesAndSelection() throws {
        let voice = try seed(AudioFileStore(rootDirectory: root))
        let selection = try JSONEncoder().encode(Selection(current: .saved(voice.id)))
        try selection.write(to: root.appendingPathComponent("voice-selection.json"))
        let workspace = IdentityWorkspace(root: root)
        let before = try workspace.legacyInventory()
        XCTAssertTrue(try workspace.legacyNeedsClaim())
        XCTAssertTrue(try AudioFileStore(rootDirectory: workspace.dataRoot(for: a)).savedVoices().isEmpty)
        let claimed = try workspace.claimLegacy(for: a)
        XCTAssertEqual(claimed, before)
        XCTAssertEqual(try workspace.legacyInventory(), before)
        let newRoot = try workspace.dataRoot(for: a)
        let store = try AudioFileStore(rootDirectory: newRoot)
        XCTAssertEqual(store.savedVoices().first?.id, voice.id)
        XCTAssertEqual(try Data(contentsOf: store.managedURL(for: voice.referenceAudio)), Data([1,2,3,4,5]))
        XCTAssertEqual(try Data(contentsOf: newRoot.appendingPathComponent("voice-selection.json")), selection)
        XCTAssertFalse(try workspace.legacyNeedsClaim())
        XCTAssertThrowsError(try workspace.claimLegacy(for: b))
        XCTAssertTrue(try AudioFileStore(rootDirectory: workspace.dataRoot(for: b)).savedVoices().isEmpty)
        XCTAssertEqual(try workspace.claimLegacy(for: a), before)
        XCTAssertEqual(try workspace.dataRoot(for: a), newRoot)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("LegacyBackups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0].appendingPathComponent("ManagedAudio/" + voice.referenceAudio.fileName)), Data([1,2,3,4,5]))
    }
    func testClaimConflictLeavesOldNamespaceAndOriginalAudioUnchanged() throws {
        let voice = try seed(AudioFileStore(rootDirectory: root))
        let workspace = IdentityWorkspace(root: root)
        let before = try workspace.dataRoot(for: a)
        let conflicting = before.appendingPathComponent("ManagedAudio/" + voice.referenceAudio.fileName)
        try FileManager.default.createDirectory(at: conflicting.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9]).write(to: conflicting)
        XCTAssertThrowsError(try workspace.claimLegacy(for: a))
        XCTAssertEqual(try workspace.dataRoot(for: a), before)
        XCTAssertEqual(try Data(contentsOf: conflicting), Data([9]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("ManagedAudio/" + voice.referenceAudio.fileName)), Data([1,2,3,4,5]))
        XCTAssertTrue(try workspace.legacyNeedsClaim())
    }
    func testMalformedMetadataAndSymlinksStopClaimWithoutDeletingAnything() throws {
        _ = try seed(AudioFileStore(rootDirectory: root))
        let workspace = IdentityWorkspace(root: root)
        let bad = root.appendingPathComponent("Metadata/voice-invalid.json")
        try Data("invalid".utf8).write(to: bad)
        XCTAssertThrowsError(try workspace.claimLegacy(for: a))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ManagedAudio/linked.wav"), withDestinationURL: root.appendingPathComponent("source.wav"))
        XCTAssertThrowsError(try workspace.legacyInventory())
    }
    func testOwnerManifestMismatchFailsClosed() throws {
        let workspace = IdentityWorkspace(root: root)
        _ = try workspace.dataRoot(for: a)
        let manifest = root.appendingPathComponent("Accounts/\(a.namespace)/owner.json")
        try JSONEncoder().encode(b).write(to: manifest)
        XCTAssertThrowsError(try workspace.dataRoot(for: a))
    }
    func testCurrentVoiceAndPrivateCacheDoNotCrossNamespaces() throws {
        let workspace = IdentityWorkspace(root: root)
        let rootA = try workspace.dataRoot(for: a), rootB = try workspace.dataRoot(for: b)
        try Data("private-selection-A".utf8).write(to: rootA.appendingPathComponent("voice-selection.json"))
        let cacheA = OpenVoicePackStore(rootDirectory: root.appendingPathComponent("RendererPacks"), privateCacheRoot: rootA.appendingPathComponent("RendererCache"))
        let cacheB = OpenVoicePackStore(rootDirectory: root.appendingPathComponent("RendererPacks"), privateCacheRoot: rootB.appendingPathComponent("RendererCache"))
        XCTAssertEqual(cacheA.installedPackURL, cacheB.installedPackURL)
        XCTAssertNotEqual(cacheA.cacheDirectory, cacheB.cacheDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootB.appendingPathComponent("voice-selection.json").path))
        XCTAssertEqual(try workspace.dataRoot(for: a), rootA)
    }
    func testSymlinkCannotExposeAnotherAccountsFile() throws {
        let workspace = IdentityWorkspace(root: root)
        let storeA = try AudioFileStore(rootDirectory: workspace.dataRoot(for: a))
        let voice = try seed(storeA)
        let rootB = try workspace.dataRoot(for: b)
        let storeB = try AudioFileStore(rootDirectory: rootB)
        let link = rootB.appendingPathComponent("ManagedAudio/" + voice.referenceAudio.fileName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: storeA.managedURL(for: voice.referenceAudio))
        XCTAssertThrowsError(try storeB.managedURL(for: voice.referenceAudio))
        XCTAssertThrowsError(try storeB.importAudio(from: link, duration: 1))
    }
    func testInterruptedJournalCommitRecoversForSameOwnerOnly() throws {
        let voice = try seed(AudioFileStore(rootDirectory: root))
        let workspace = IdentityWorkspace(root: root)
        let before = try workspace.dataRoot(for: a)
        _ = try workspace.claimLegacy(for: a)
        let claimed = try workspace.dataRoot(for: a)
        let base = root.appendingPathComponent("Accounts/" + a.namespace)
        // Reproduce crash state: journal durable, active pointer still at previous revision.
        try FileManager.default.removeItem(at: base.appendingPathComponent("legacy-claim-complete.json"))
        try JSONSerialization.data(withJSONObject: ["revision": before.lastPathComponent]).write(to: base.appendingPathComponent("current.json"), options: .atomic)
        XCTAssertTrue(try AudioFileStore(rootDirectory: workspace.dataRoot(for: b)).savedVoices().isEmpty)
        XCTAssertEqual(try workspace.dataRoot(for: a), claimed)
        XCTAssertEqual(try AudioFileStore(rootDirectory: claimed).savedVoices().first?.id, voice.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("legacy-claim-complete.json").path))
    }
    func testClaimDoesNotOverwriteAccountsCurrentVoice() throws {
        let voice = try seed(AudioFileStore(rootDirectory: root))
        try JSONEncoder().encode(Selection(current: .saved(voice.id))).write(to: root.appendingPathComponent("voice-selection.json"))
        let workspace = IdentityWorkspace(root: root)
        let existing = try workspace.dataRoot(for: a)
        let selected = try JSONEncoder().encode(Selection(current: .systemDefault))
        try selected.write(to: existing.appendingPathComponent("voice-selection.json"))
        _ = try workspace.claimLegacy(for: a)
        XCTAssertEqual(try Data(contentsOf: workspace.dataRoot(for: a).appendingPathComponent("voice-selection.json")), selected)
    }
}
