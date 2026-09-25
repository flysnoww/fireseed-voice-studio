import Foundation

/// Owns staged and persistent audio files and their small JSON metadata records.
public final class AudioFileStore {
    public static let supportedAudioExtensions: Set<String> = ["m4a", "aac", "wav", "aif", "aiff", "caf", "mp3"]

    private let stagingDirectory: URL
    private let audioDirectory: URL
    private let metadataDirectory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.stagingDirectory = rootDirectory.appendingPathComponent("StagedAudio", isDirectory: true).standardizedFileURL
        self.audioDirectory = rootDirectory.appendingPathComponent("ManagedAudio", isDirectory: true).standardizedFileURL
        self.metadataDirectory = rootDirectory.appendingPathComponent("Metadata", isDirectory: true).standardizedFileURL
        self.fileManager = fileManager
        for directory in [stagingDirectory, audioDirectory, metadataDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// AVAudioRecorder writes only to a destination issued by this store.
    public func recordingDestination() -> URL {
        stagingDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
    }

    public func registerRecording(at destination: URL, duration: TimeInterval) throws -> AudioAsset {
        let standardized = destination.standardizedFileURL
        guard standardized.deletingLastPathComponent() == stagingDirectory else {
            throw VoiceStudioError.invalidManagedAudioPath
        }
        return try registerStagedFile(at: standardized, duration: duration)
    }

    public func discardRecording(at destination: URL) throws {
        let standardized = destination.standardizedFileURL
        guard standardized.deletingLastPathComponent() == stagingDirectory else {
            throw VoiceStudioError.invalidManagedAudioPath
        }
        if fileManager.fileExists(atPath: standardized.path) {
            try fileManager.removeItem(at: standardized)
        }
    }

    /// Copies an imported document into app-managed staging before its security-scoped URL expires.
    public func importAudio(from source: URL, duration: TimeInterval) throws -> AudioAsset {
        let ext = source.pathExtension.lowercased()
        guard Self.supportedAudioExtensions.contains(ext) else {
            throw VoiceStudioError.unsupportedAudioFormat(ext.isEmpty ? "unknown" : ext)
        }
        try validateFile(at: source, duration: duration)
        let id = UUID()
        let fileName = "\(id.uuidString.lowercased()).\(ext)"
        let destination = stagingDirectory.appendingPathComponent(fileName)
        try fileManager.copyItem(at: source, to: destination)
        return AudioAsset(id: id, fileName: fileName, duration: duration)
    }

    public func managedURL(for asset: AudioAsset) throws -> URL {
        let ext = URL(fileURLWithPath: asset.fileName).pathExtension.lowercased()
        guard Self.supportedAudioExtensions.contains(ext),
              asset.fileName == "\(asset.id.uuidString.lowercased()).\(ext)" else {
            throw VoiceStudioError.invalidManagedAudioPath
        }
        let directory = asset.persistenceState == .persistent ? audioDirectory : stagingDirectory
        let url = directory.appendingPathComponent(asset.fileName).standardizedFileURL
        guard url.deletingLastPathComponent() == directory else {
            throw VoiceStudioError.invalidManagedAudioPath
        }
        guard fileManager.fileExists(atPath: url.path) else { throw VoiceStudioError.missingManagedAudio }
        return url
    }

    public func promoteToPersistent(_ asset: AudioAsset) throws -> AudioAsset {
        if asset.persistenceState == .persistent {
            _ = try managedURL(for: asset)
            return asset
        }
        let source = try managedURL(for: asset)
        let destination = audioDirectory.appendingPathComponent(asset.fileName)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw VoiceStudioError.invalidManagedAudioPath
        }
        try fileManager.copyItem(at: source, to: destination)
        let saved = AudioAsset(id: asset.id, fileName: asset.fileName, duration: asset.duration,
                               createdAt: asset.createdAt, sourceVoiceID: asset.sourceVoiceID,
                               text: asset.text, persistenceState: .persistent)
        try write(saved, named: "audio-\(saved.id.uuidString.lowercased()).json")
        try fileManager.removeItem(at: source)
        return saved
    }

    /// Cache eviction can remove staged files only. Persistent assets are never deleted here.
    public func removeTemporaryAudio(_ asset: AudioAsset) throws {
        guard asset.persistenceState == .temporary else { return }
        let url = try managedURL(for: asset)
        try fileManager.removeItem(at: url)
    }

    public func saveVoice(_ voice: VoiceAsset) throws -> VoiceAsset {
        let reference = try promoteToPersistent(voice.referenceAudio)
        let saved = VoiceAsset(id: voice.id, name: voice.name, sourceType: voice.sourceType,
                               referenceAudio: reference, languageHint: voice.languageHint,
                               defaultAccent: voice.defaultAccent, defaultAttributes: voice.defaultAttributes,
                               createdAt: voice.createdAt, updatedAt: .now)
        try write(saved, named: "voice-\(saved.id.uuidString.lowercased()).json")
        return saved
    }

    public func savedAudioAssets() -> [AudioAsset] {
        loadRecords(AudioAsset.self, prefix: "audio-").filter {
            $0.persistenceState == .persistent && (try? managedURL(for: $0)) != nil
        }
    }

    public func savedVoices() -> [VoiceAsset] {
        loadRecords(VoiceAsset.self, prefix: "voice-").filter {
            $0.referenceAudio.persistenceState == .persistent && (try? managedURL(for: $0.referenceAudio)) != nil
        }
    }

    private func registerStagedFile(at url: URL, duration: TimeInterval) throws -> AudioAsset {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedAudioExtensions.contains(ext) else { throw VoiceStudioError.unsupportedAudioFormat(ext) }
        try validateFile(at: url, duration: duration)
        let id = UUID()
        let fileName = "\(id.uuidString.lowercased()).\(ext)"
        let destination = stagingDirectory.appendingPathComponent(fileName)
        try fileManager.moveItem(at: url, to: destination)
        return AudioAsset(id: id, fileName: fileName, duration: duration)
    }

    private func validateFile(at url: URL, duration: TimeInterval) throws {
        guard duration.isFinite, duration > 0,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 0,
              fileManager.fileExists(atPath: url.path) else {
            throw VoiceStudioError.invalidAudioFile
        }
    }

    private func write<T: Encodable>(_ record: T, named fileName: String) throws {
        let destination = metadataDirectory.appendingPathComponent(fileName)
        try encoder.encode(record).write(to: destination, options: .atomic)
    }

    private func loadRecords<T: Decodable>(_ type: T.Type, prefix: String) -> [T] {
        guard let urls = try? fileManager.contentsOfDirectory(at: metadataDirectory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? decoder.decode(type, from: (try? Data(contentsOf: $0)) ?? Data()) }
    }
}