import Foundation

public enum AudioPersistenceState: String, Codable, Sendable {
    case temporary
    case persistent
}

public enum AudioRenderMode: String, Codable, Sendable {
    case preview
    case generate
}

public enum AudioCacheKind: String, Codable, Sendable {
    case preview
    case generated
}

public struct AudioAsset: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// A generated file name relative to the managed audio store, never an arbitrary URL.
    public let fileName: String
    public let duration: TimeInterval
    public let createdAt: Date
    public let sourceVoiceID: UUID?
    public let text: String?
    public let persistenceState: AudioPersistenceState

    public init(id: UUID = UUID(), fileName: String, duration: TimeInterval, createdAt: Date = Date(),
                sourceVoiceID: UUID? = nil, text: String? = nil,
                persistenceState: AudioPersistenceState = .temporary) {
        self.id = id
        self.fileName = fileName
        self.duration = duration
        self.createdAt = createdAt
        self.sourceVoiceID = sourceVoiceID
        self.text = text
        self.persistenceState = persistenceState
    }
}

public enum VoiceSourceType: String, Codable, Sendable {
    case record
    case imported
    case random
    case builtIn
}

public struct VoiceAsset: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let sourceType: VoiceSourceType
    /// The concrete managed audio asset is the durable voice reference.
    public let referenceAudio: AudioAsset
    public let languageHint: String?
    public let defaultAccent: String?
    public let defaultAttributes: [String: String]
    public let createdAt: Date
    public let updatedAt: Date

    /// Voices are created as part of the save action; keep this computed to preserve the stored schema.
    public var savedAt: Date { createdAt }

    public init(id: UUID = UUID(), name: String, sourceType: VoiceSourceType, referenceAudio: AudioAsset,
                languageHint: String? = nil, defaultAccent: String? = nil,
                defaultAttributes: [String: String] = [:], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sourceType = sourceType
        self.referenceAudio = referenceAudio
        self.languageHint = languageHint
        self.defaultAccent = defaultAccent
        self.defaultAttributes = defaultAttributes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct VoiceRequest: Codable, Equatable, Sendable {
    public let text: String
    public let voiceID: UUID
    public let language: String?
    public let accent: String?
    public let attributes: [String: String]
    public let renderMode: AudioRenderMode

    public init(text: String, voiceID: UUID, language: String? = nil, accent: String? = nil,
                attributes: [String: String] = [:], renderMode: AudioRenderMode) {
        self.text = text
        self.voiceID = voiceID
        self.language = language
        self.accent = accent
        self.attributes = attributes
        self.renderMode = renderMode
    }
}

public enum RendererCapability: String, Codable, CaseIterable, Sendable {
    case local
    case streaming
    case referenceVoice
    case voiceClone = "voice_clone"
    case voiceDesign = "voice_design"
    case timbreControl = "timbre_control"
    case emotionControl = "emotion_control"
    case accentControl = "accent_control"
    case speedControl = "speed_control"
    case instructionControl = "instruction_control"
    case languageSelection = "language_selection"
    case dialectControl = "dialect_control"
    case referenceTranscriptConditioning = "reference_transcript_conditioning"
    case attributeControl = "attribute_control"
}

public enum CapabilitySupport: String, Codable, Sendable {
    case supported
    case approximate
    case unsupported
}

/// Model-neutral, serializable capability claims for one installed renderer pack.
public struct RendererCapabilityManifest: Codable, Equatable, Sendable {
    public let support: [RendererCapability: CapabilitySupport]
    public let supportedLanguages: [String]
    public let supportedDialects: [String]

    public init(support: [RendererCapability: CapabilitySupport],
                supportedLanguages: [String] = [], supportedDialects: [String] = []) {
        self.support = support
        self.supportedLanguages = supportedLanguages
        self.supportedDialects = supportedDialects
    }

    public func status(for capability: RendererCapability) -> CapabilitySupport {
        support[capability] ?? .unsupported
    }
}

public struct RendererPackFile: Codable, Equatable, Sendable {
    public let path: String
    public let bytes: Int64
    public let sha256: String

    public init(path: String, bytes: Int64, sha256: String) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// Small pack identity and inventory contract; implementation metadata stays inside the pack.
public struct RendererPackManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let packID: String
    public let rendererID: String
    public let variant: String
    public let version: String
    public let requiredFiles: [RendererPackFile]
    public let capabilities: RendererCapabilityManifest
    public let compatibilityVersion: Int

    public init(schemaVersion: Int = 1, packID: String, rendererID: String, variant: String,
                version: String, requiredFiles: [RendererPackFile],
                capabilities: RendererCapabilityManifest, compatibilityVersion: Int = 1) {
        self.schemaVersion = schemaVersion
        self.packID = packID
        self.rendererID = rendererID
        self.variant = variant
        self.version = version
        self.requiredFiles = requiredFiles
        self.capabilities = capabilities
        self.compatibilityVersion = compatibilityVersion
    }

    public func isStructurallyValid() -> Bool {
        schemaVersion == 1 && compatibilityVersion > 0 && !packID.isEmpty && !rendererID.isEmpty &&
        !variant.isEmpty && !version.isEmpty && !requiredFiles.isEmpty &&
        requiredFiles.allSatisfy { file in
            file.bytes > 0 && file.sha256.count == 64 &&
            file.sha256.allSatisfy({ $0.isHexDigit }) && !file.path.isEmpty &&
            !file.path.hasPrefix("/") && !file.path.contains("..") && !file.path.contains("\\")
        }
    }
}

public struct RendererCapabilities: Equatable, Sendable {
    private let values: [RendererCapability: CapabilitySupport]

    public init(_ values: [RendererCapability: CapabilitySupport] = [:]) {
        self.values = values
    }

    public func support(for capability: RendererCapability) -> CapabilitySupport {
        values[capability] ?? .unsupported
    }

    public init(manifest: RendererCapabilityManifest) {
        self.values = manifest.support
    }
}

public enum RendererResult: Equatable, Sendable {
    case unsupported(RendererCapability)
    case audio(AudioAsset, approximation: String?)
    case renderedFile(URL, duration: TimeInterval, approximation: String?)
    case failure(String)
}

public protocol RendererAdapter: Sendable {
    var capabilities: RendererCapabilities { get }
    func installPack(at folder: URL) async throws -> RendererCapabilityManifest
    func loadVoice(_ voice: VoiceAsset, referenceAudioURL: URL) async -> CapabilitySupport
    func synthesize(_ request: VoiceRequest) async -> RendererResult
}

/// Used until a real renderer is selected. It reports absence instead of simulating audio.
public struct UnavailableRenderer: RendererAdapter {
    public let capabilities = RendererCapabilities()

    public init() {}

    public func installPack(at folder: URL) async throws -> RendererCapabilityManifest {
        throw VoiceStudioError.rendererUnavailable
    }

    public func loadVoice(_ voice: VoiceAsset, referenceAudioURL: URL) async -> CapabilitySupport {
        .unsupported
    }

    public func synthesize(_ request: VoiceRequest) async -> RendererResult {
        .unsupported(.voiceClone)
    }
}

public enum VoiceStudioError: Error, LocalizedError, Equatable {
    case microphonePermissionDenied
    case unsupportedAudioFormat(String)
    case invalidAudioFile
    case missingManagedAudio
    case invalidManagedAudioPath
    case recordingFailed
    case rendererUnavailable
    case invalidRendererPack

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is off. Allow it in Settings to record a voice reference."
        case .unsupportedAudioFormat(let ext):
            return "The .\(ext) audio format is not supported. Choose M4A, AAC, WAV, AIFF, CAF, or MP3."
        case .invalidAudioFile:
            return "This audio file is empty or cannot be played."
        case .missingManagedAudio:
            return "The managed audio file is missing. Import or record the reference again."
        case .invalidManagedAudioPath:
            return "The audio asset does not point to a file managed by Voice Studio."
        case .recordingFailed:
            return "Recording stopped before a valid audio file was created."
        case .rendererUnavailable:
            return "No local voice renderer is available."
        case .invalidRendererPack:
            return "This local voice pack is invalid or incompatible."
        }
    }
}
