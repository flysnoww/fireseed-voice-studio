import Foundation
import CryptoKit

/// Exact issuer + subject identity. Email is never an ownership key.
public struct AssetOwner: Codable, Equatable, Sendable {
    public let issuer: String
    public let subject: String
    public init(issuer: String, subject: String) throws {
        guard let url = URLComponents(string: issuer), url.scheme == "https", url.host != nil,
              url.path == "/oidc", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkspaceError.invalidOwner }
        self.issuer = issuer; self.subject = subject
    }
    private enum CodingKeys: String, CodingKey { case issuer, subject }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(issuer: values.decode(String.self, forKey: .issuer), subject: values.decode(String.self, forKey: .subject))
    }
    public var namespace: String {
        let data = try! JSONEncoder().encode([issuer, subject])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum WorkspaceError: Error { case invalidOwner, corruptManifest, alreadyClaimed, conflictingAsset, unsafeFile }

public struct LegacyAssetInventory: Codable, Equatable, Sendable {
    public let voices: Int
    public let audio: Int
    public let files: [String: String]
    public var isEmpty: Bool { files.isEmpty }
}

/// Per-owner files, metadata and Current Voice. Atomic pointer commits keep a failed
/// claim invisible. The old dataset and every previous revision remain recoverable.
public final class IdentityWorkspace {
    private struct Pointer: Codable { let revision: String }
    private struct Claim: Codable { let owner: AssetOwner; let revision: String; let inventory: LegacyAssetInventory }
    public let root: URL
    private let fm: FileManager
    private let privateNames = ["ManagedAudio", "Metadata", "voice-selection.json", "Appearance"]
    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath(); fm = fileManager
    }

    private func account(_ owner: AssetOwner) -> URL { root.appendingPathComponent("Accounts/" + owner.namespace) }
    private func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    private func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    private func revisionURL(_ revision: String, owner: AssetOwner) throws -> URL {
        guard UUID(uuidString: revision) != nil else { throw WorkspaceError.corruptManifest }
        return account(owner).appendingPathComponent("Versions/" + revision)
    }

    public func dataRoot(for owner: AssetOwner) throws -> URL {
        let base = account(owner)
        try fm.createDirectory(at: base.appendingPathComponent("Versions"), withIntermediateDirectories: true)
        let ownership = base.appendingPathComponent("owner.json")
        if fm.fileExists(atPath: ownership.path) {
            guard try read(AssetOwner.self, ownership) == owner else { throw WorkspaceError.corruptManifest }
        } else { try write(owner, ownership) }
        let pointerURL = base.appendingPathComponent("current.json")
        if !fm.fileExists(atPath: pointerURL.path) {
            let revision = UUID().uuidString
            try fm.createDirectory(at: try revisionURL(revision, owner: owner), withIntermediateDirectories: true)
            try write(Pointer(revision: revision), pointerURL)
        }
        let journal = root.appendingPathComponent("legacy-claim.json")
        let completed = base.appendingPathComponent("legacy-claim-complete.json")
        if fm.fileExists(atPath: journal.path), !fm.fileExists(atPath: completed.path) {
            let claim = try read(Claim.self, journal)
            if claim.owner == owner {
                guard fm.fileExists(atPath: try revisionURL(claim.revision, owner: owner).path) else { throw WorkspaceError.corruptManifest }
                try write(Pointer(revision: claim.revision), pointerURL)
                try write(claim, completed)
            }
        }
        let pointer = try read(Pointer.self, pointerURL)
        let data = try revisionURL(pointer.revision, owner: owner)
        guard fm.fileExists(atPath: data.path) else { throw WorkspaceError.corruptManifest }
        return data
    }

    public func legacyInventory() throws -> LegacyAssetInventory {
        var files: [String: String] = [:]
        for name in privateNames {
            let source = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw WorkspaceError.unsafeFile }
            let entries: [URL]
            if values.isDirectory == true {
                guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw WorkspaceError.unsafeFile }
                entries = enumerator.compactMap { $0 as? URL }
            } else { entries = [source] }
            for file in entries {
                let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attrs.isSymbolicLink != true else { throw WorkspaceError.unsafeFile }
                guard attrs.isRegularFile == true else { continue }
                let canonical = file.standardizedFileURL.resolvingSymlinksInPath()
                guard canonical.path.hasPrefix(root.path + "/") else { throw WorkspaceError.unsafeFile }
                let relative = String(canonical.path.dropFirst(root.path.count + 1))
                files[relative] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
            }
        }
        return LegacyAssetInventory(voices: files.keys.filter { $0.hasPrefix("Metadata/voice-") }.count,
                                    audio: files.keys.filter { $0.hasPrefix("Metadata/audio-") }.count, files: files)
    }
    public func legacyNeedsClaim() throws -> Bool {
        guard !fm.fileExists(atPath: root.appendingPathComponent("legacy-claim.json").path) else { return false }
        return !(try legacyInventory()).isEmpty
    }

    /// Call only after explicit user confirmation and after stopping the old model.
    /// A crash after journal commit is recovered for the SAME owner on the next call.
    @discardableResult public func claimLegacy(for owner: AssetOwner) throws -> LegacyAssetInventory {
        let active = try dataRoot(for: owner)
        let journal = root.appendingPathComponent("legacy-claim.json")
        if fm.fileExists(atPath: journal.path) {
            let claim = try read(Claim.self, journal)
            guard claim.owner == owner else { throw WorkspaceError.alreadyClaimed }
            let target = try revisionURL(claim.revision, owner: owner)
            guard fm.fileExists(atPath: target.path) else { throw WorkspaceError.corruptManifest }
            // Repeating a completed claim must never rewind to an obsolete revision.
            let completed = account(owner).appendingPathComponent("legacy-claim-complete.json")
            if !fm.fileExists(atPath: completed.path) {
                try write(Pointer(revision: claim.revision), account(owner).appendingPathComponent("current.json"))
                try write(claim, completed)
            }
            return claim.inventory
        }
        let inventory = try legacyInventory()
        guard !inventory.isEmpty else { return inventory }
        // Refuse a partial or undecodable library instead of silently dropping records.
        var audioByID: [UUID: AudioAsset] = [:]
        for relative in inventory.files.keys where relative.hasPrefix("Metadata/audio-") {
            let audio = try read(AudioAsset.self, root.appendingPathComponent(relative))
            guard relative == "Metadata/audio-\(audio.id.uuidString.lowercased()).json",
                  audio.persistenceState == .persistent,
                  audio.fileName == "\(audio.id.uuidString.lowercased()).\(URL(fileURLWithPath: audio.fileName).pathExtension)",
                  inventory.files["ManagedAudio/" + audio.fileName] != nil else { throw WorkspaceError.corruptManifest }
            audioByID[audio.id] = audio
        }
        for relative in inventory.files.keys where relative.hasPrefix("Metadata/voice-") {
            let voice = try read(VoiceAsset.self, root.appendingPathComponent(relative))
            guard relative == "Metadata/voice-\(voice.id.uuidString.lowercased()).json",
                  let audio = audioByID[voice.referenceAudio.id], audio.fileName == voice.referenceAudio.fileName else { throw WorkspaceError.corruptManifest }
        }
        let revision = UUID().uuidString
        let target = try revisionURL(revision, owner: owner)
        try fm.copyItem(at: active, to: target)
        do {
            // Keep an independent byte-verified pre-migration snapshot, in addition to originals.
            let backup = root.appendingPathComponent("LegacyBackups/" + revision)
            for (relative, digest) in inventory.files.sorted(by: { $0.key < $1.key }) {
                let source = root.appendingPathComponent(relative)
                let snapshot = backup.appendingPathComponent(relative)
                try fm.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: snapshot)
                guard SHA256.hash(data: try Data(contentsOf: snapshot)).map({ String(format: "%02x", $0) }).joined() == digest else { throw WorkspaceError.corruptManifest }
                let destination = target.appendingPathComponent(relative)
                if fm.fileExists(atPath: destination.path) {
                    // Preserve this account's newer Current Voice preference.
                    if relative == "voice-selection.json" { continue }
                    guard try Data(contentsOf: destination) == Data(contentsOf: snapshot) else { throw WorkspaceError.conflictingAsset }
                } else {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: snapshot, to: destination)
                }
            }
            try write(inventory, backup.appendingPathComponent("inventory.json"))
            let claim = Claim(owner: owner, revision: revision, inventory: inventory)
            try write(claim, target.appendingPathComponent("legacy-provenance.json"))
            // One atomic journal reserves ownership before the pointer can expose it.
            try write(claim, journal)
            try write(Pointer(revision: revision), account(owner).appendingPathComponent("current.json"))
            try write(claim, account(owner).appendingPathComponent("legacy-claim-complete.json"))
            return inventory
        } catch {
            // Preserve prepared revision if the journal exists: it may need crash recovery.
            if !fm.fileExists(atPath: journal.path) { try? fm.removeItem(at: target) }
            throw error
        }
    }
}
