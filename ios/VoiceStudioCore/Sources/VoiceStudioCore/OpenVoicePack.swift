import CryptoKit
import Foundation

public struct OpenVoicePackManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let bytes: Int64
        public let sha256: String

        public init(path: String, bytes: Int64, sha256: String) {
            self.path = path
            self.bytes = bytes
            self.sha256 = sha256.lowercased()
        }
    }

    public let formatVersion: Int
    public let packID: String
    public let sourceRepository: String
    public let sourceRevision: String
    public let converterRepository: String
    public let converterRevision: String
    public let license: String
    public let computeUnits: String
    public let files: [File]

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case packID = "pack_id"
        case sourceRepository = "source_repository"
        case sourceRevision = "source_revision"
        case converterRepository = "converter_repository"
        case converterRevision = "converter_revision"
        case license
        case computeUnits = "compute_units"
        case files
    }

    public init(formatVersion: Int = 1, packID: String = "openvoice-v2-coreml",
                sourceRepository: String, sourceRevision: String,
                converterRepository: String, converterRevision: String,
                license: String, computeUnits: String, files: [File]) {
        self.formatVersion = formatVersion
        self.packID = packID
        self.sourceRepository = sourceRepository
        self.sourceRevision = sourceRevision.lowercased()
        self.converterRepository = converterRepository
        self.converterRevision = converterRevision.lowercased()
        self.license = license
        self.computeUnits = computeUnits
        self.files = files
    }
}

public enum OpenVoicePackError: Error, Equatable {
    case unreadableManifest
    case incompatibleManifest
    case unsafePath(String)
    case unexpectedFiles
    case missingFile(String)
    case invalidFile(String)
}

/// Manages optional Core ML packages independently from canonical Voice/Audio assets.
public struct OpenVoicePackStore: Sendable {
    struct PinnedFile: Equatable, Sendable {
        let bytes: Int64
        let sha256: String
    }

    public static let manifestName = "manifest.json"
    public static let packID = "openvoice-v2-coreml"
    public static let sourceRepository = "myshell-ai/OpenVoice"
    public static let sourceRevision = "3a72f7931fce14857c34a15b2d83ffbcaa755e16"
    public static let converterRepository = "mlboydaisuke/OpenVoice-V2-CoreML"
    public static let converterRevision = "b0f10347769c88bb6df26e268d4b84bc7237fdeb"
    public static let installFolderName = "OpenVoiceV2"
    public static let cacheFolderName = "OpenVoiceV2"
    static let pinnedFiles: [String: PinnedFile] = [
        "OpenVoice_SpeakerEncoder.mlpackage/Manifest.json": .init(bytes: 617, sha256: "68da0c2b9f407a7d9cb39c597807ff4e854bc5ae4976718182af4def2605970a"),
        "OpenVoice_SpeakerEncoder.mlpackage/Data/com.apple.CoreML/model.mlmodel": .init(bytes: 25_281, sha256: "b2eadb91cb59157aa4d4958bc6becee86758faf273de240b2b7a4969971fe7e5"),
        "OpenVoice_SpeakerEncoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin": .init(bytes: 1_627_840, sha256: "6b50c4ca00b72862f7cd974f9bef7d1dd36d2a86adc0b6b626116fb26b5cc6de"),
        "OpenVoice_VoiceConverter.mlpackage/Manifest.json": .init(bytes: 617, sha256: "66aad1bb6ba0d360556db96babf2a2e42124a07612a74a351812d10f6ad9eec0"),
        "OpenVoice_VoiceConverter.mlpackage/Data/com.apple.CoreML/model.mlmodel": .init(bytes: 482_492, sha256: "c7ca229e9fe7f8508884512f6c1100c1fa38fd15bb5e7b9b2641246733cf8fc0"),
        "OpenVoice_VoiceConverter.mlpackage/Data/com.apple.CoreML/weights/weight.bin": .init(bytes: 63_887_808, sha256: "bc5c2c0952a4146a74ae7c4dce9ccda8c294af8b41ee4dbadc7d47077d8104ea"),
    ]

    public let rootDirectory: URL
    public let installedPackURL: URL
    public let cacheDirectory: URL
    private let expectedSourceRevision: String
    private let expectedConverterRevision: String
    private let expectedFiles: [String: PinnedFile]

    public init(rootDirectory: URL) {
        self.init(rootDirectory: rootDirectory,
                  sourceRevision: Self.sourceRevision,
                  converterRevision: Self.converterRevision,
                  expectedFiles: Self.pinnedFiles)
    }

    init(rootDirectory: URL, sourceRevision: String, converterRevision: String,
         expectedFiles: [String: PinnedFile]) {
        self.rootDirectory = rootDirectory
        expectedSourceRevision = sourceRevision.lowercased()
        expectedConverterRevision = converterRevision.lowercased()
        self.expectedFiles = expectedFiles
        installedPackURL = rootDirectory.appendingPathComponent(Self.installFolderName, isDirectory: true)
        cacheDirectory = rootDirectory.deletingLastPathComponent()
            .appendingPathComponent("RendererCache", isDirectory: true)
            .appendingPathComponent(Self.cacheFolderName, isDirectory: true)
    }

    @discardableResult
    public func validate(at folder: URL) throws -> OpenVoicePackManifest {
        let manifestURL = folder.appendingPathComponent(Self.manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(OpenVoicePackManifest.self, from: data) else {
            throw OpenVoicePackError.unreadableManifest
        }
        guard manifest.formatVersion == 1, manifest.packID == Self.packID,
              manifest.sourceRepository == Self.sourceRepository,
              manifest.sourceRevision == expectedSourceRevision,
              manifest.converterRepository == Self.converterRepository,
              manifest.converterRevision == expectedConverterRevision,
              manifest.license.lowercased() == "mit", manifest.computeUnits == "cpuAndGPU",
              Set(manifest.files.map(\.path)).count == manifest.files.count,
              manifest.files.count == expectedFiles.count,
              manifest.files.allSatisfy({ expectedFiles[$0.path]?.bytes == $0.bytes &&
                                           expectedFiles[$0.path]?.sha256 == $0.sha256 }),
              Self.hasValidRevision(manifest.sourceRevision), Self.hasValidRevision(manifest.converterRevision),
              manifest.files.contains(where: { $0.path.hasPrefix("OpenVoice_SpeakerEncoder.mlpackage/") }),
              manifest.files.contains(where: { $0.path.hasPrefix("OpenVoice_VoiceConverter.mlpackage/") }) else {
            throw OpenVoicePackError.incompatibleManifest
        }
        if let unsafe = manifest.files.first(where: { !Self.isSafeRelativePath($0.path) }) {
            throw OpenVoicePackError.unsafePath(unsafe.path)
        }

        let declared = Set(manifest.files.map(\.path))
        var actual = Set<String>()
        let rootPath = folder.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw OpenVoicePackError.unexpectedFiles
        }
        for case let url as URL in enumerator {
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL.path.hasPrefix(rootPath + "/") else {
                throw OpenVoicePackError.unsafePath(url.path)
            }
            let relative = String(standardizedURL.path.dropFirst(rootPath.count + 1)).replacingOccurrences(of: "\\", with: "/")
            guard Self.isSafeRelativePath(relative) else { throw OpenVoicePackError.unsafePath(relative) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw OpenVoicePackError.unsafePath(relative) }
            if values.isRegularFile == true {
                if relative != Self.manifestName { actual.insert(relative) }
            }
        }
        guard actual == declared else { throw OpenVoicePackError.unexpectedFiles }

        for file in manifest.files {
            guard Self.isSafeRelativePath(file.path) else { throw OpenVoicePackError.unsafePath(file.path) }
            guard file.bytes > 0, file.sha256.count == 64,
                  file.sha256.allSatisfy(\.isHexDigit), let url = Self.safeURL(file.path, under: folder),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == file.bytes else {
                throw OpenVoicePackError.invalidFile(file.path)
            }
            guard try Self.sha256(url) == file.sha256 else { throw OpenVoicePackError.invalidFile(file.path) }
        }
        return manifest
    }

    public func install(from source: URL) throws {
        _ = try validate(at: source)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let parent = installedPackURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent("OpenVoice-import-\(UUID().uuidString)", isDirectory: true)
        let backup = parent.appendingPathComponent("OpenVoice-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)
        _ = try validate(at: staging)
        let hadPrevious = fileManager.fileExists(atPath: installedPackURL.path)
        if hadPrevious { try fileManager.moveItem(at: installedPackURL, to: backup) }
        do {
            try fileManager.moveItem(at: staging, to: installedPackURL)
        } catch {
            if hadPrevious { try? fileManager.moveItem(at: backup, to: installedPackURL) }
            throw error
        }
        if hadPrevious { try? fileManager.removeItem(at: backup) }
    }

    public func validateInstalled() throws -> OpenVoicePackManifest { try validate(at: installedPackURL) }

    public func deleteInstalledPack() throws {
        if FileManager.default.fileExists(atPath: installedPackURL.path) {
            let fileManager = FileManager.default
            try fileManager.removeItem(at: installedPackURL)
        }
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            let fileManager = FileManager.default
            try fileManager.removeItem(at: cacheDirectory)
        }
    }

    private static func hasValidRevision(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy(\.isHexDigit)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.hasPrefix("~") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func safeURL(_ path: String, under root: URL) -> URL? {
        guard isSafeRelativePath(path) else { return nil }
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        return candidate.path.hasPrefix(root.standardizedFileURL.path + "/") ? candidate : nil
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Disposable embedding cache. Keys include the voice, source audio and pack revision.
public struct OpenVoiceSpeakerEmbeddingCache: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public func store(_ embedding: [Float], voiceID: UUID, referenceAudioID: UUID,
                      packRevision: String) throws {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite),
              packRevision.count == 40, packRevision.allSatisfy(\.isHexDigit) else {
            throw OpenVoicePackError.incompatibleManifest
        }
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let key = Self.key(voiceID: voiceID, referenceAudioID: referenceAudioID, packRevision: packRevision)
        try JSONEncoder().encode(embedding).write(to: rootDirectory.appendingPathComponent("\(key).json"), options: .atomic)
    }

    public func load(voiceID: UUID, referenceAudioID: UUID, packRevision: String) -> [Float]? {
        guard packRevision.count == 40 else { return nil }
        let url = rootDirectory.appendingPathComponent("\(Self.key(voiceID: voiceID, referenceAudioID: referenceAudioID, packRevision: packRevision)).json")
        guard let data = try? Data(contentsOf: url),
              let embedding = try? JSONDecoder().decode([Float].self, from: data),
              !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return nil }
        return embedding
    }

    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: rootDirectory.path) { try FileManager.default.removeItem(at: rootDirectory) }
    }

    private static func key(voiceID: UUID, referenceAudioID: UUID, packRevision: String) -> String {
        let raw = "\(voiceID.uuidString.lowercased())|\(referenceAudioID.uuidString.lowercased())|\(packRevision.lowercased())"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
