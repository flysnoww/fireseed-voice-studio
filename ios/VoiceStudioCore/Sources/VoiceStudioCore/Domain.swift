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

public enum VoiceSelection: Codable, Equatable, Hashable, Sendable {
    case saved(UUID)
    case systemDefault

    public var savedVoiceID: UUID? {
        guard case .saved(let id) = self else { return nil }
        return id
    }
}

public enum VoiceShape: String, Codable, CaseIterable, Sendable {
    case bright, deep, soft, powerful, youthful, mature, thin, clear, rough
}

public struct VoiceShaping: Codable, Equatable, Sendable {
    public let values: [VoiceShape: Double]
    public init(values: [VoiceShape: Double] = [:]) { self.values = values }
}

public enum VoiceExpression: String, Codable, CaseIterable, Sendable {
    case lively, melancholic, serious, gentle, excited, calm, angry, whisper
}

public struct VoiceRequest: Codable, Equatable, Sendable {
    public let text: String
    public let voice: VoiceSelection
    public let language: String?
    public let accent: String?
    public let shaping: VoiceShaping
    public let expression: VoiceExpression?
    /// Playback rate multiplier. 1.0 is unchanged.
    public let speed: Double
    /// Pitch shift in cents. 0 is unchanged.
    public let pitch: Double
    public let renderMode: AudioRenderMode

    public init(text: String, voice: VoiceSelection, language: String? = nil, accent: String? = nil,
                shaping: VoiceShaping = VoiceShaping(), expression: VoiceExpression? = nil,
                speed: Double = 1, pitch: Double = 0, renderMode: AudioRenderMode) {
        self.text = text
        self.voice = voice
        self.language = language
        self.accent = accent
        self.shaping = shaping
        self.expression = expression
        self.speed = speed
        self.pitch = pitch
        self.renderMode = renderMode
    }

    public init(text: String, voiceID: UUID, language: String? = nil, accent: String? = nil,
                renderMode: AudioRenderMode) {
        self.init(text: text, voice: .saved(voiceID), language: language,
                  accent: accent, renderMode: renderMode)
    }
}

public enum CapabilitySupport: String, Codable, Sendable {
    case supported
    case approximate
    case unsupported
}

public enum VoiceCapability: String, Codable, CaseIterable, Sendable {
    case speechGeneration
    case voiceCloning
    case languageSelection
    case accentSelection
    case speed
    case pitch
}

public struct CapabilityProfile: Codable, Equatable, Sendable {
    public let support: [VoiceCapability: CapabilitySupport]
    public let shaping: [VoiceShape: CapabilitySupport]
    public let expressions: [VoiceExpression: CapabilitySupport]
    public let languages: [String]
    public let accentsByLanguage: [String: [String]]

    public init(support: [VoiceCapability: CapabilitySupport] = [:],
                shaping: [VoiceShape: CapabilitySupport] = [:],
                expressions: [VoiceExpression: CapabilitySupport] = [:],
                languages: [String] = [], accentsByLanguage: [String: [String]] = [:]) {
        self.support = support
        self.shaping = shaping
        self.expressions = expressions
        self.languages = languages
        self.accentsByLanguage = accentsByLanguage
    }

    public func status(for capability: VoiceCapability) -> CapabilitySupport {
        support[capability] ?? .unsupported
    }

    public func supports(language: String?) -> Bool {
        guard let language else { return !languages.isEmpty }
        let requested = language.lowercased().replacingOccurrences(of: "_", with: "-")
        return languages.contains { available in
            let candidate = available.lowercased().replacingOccurrences(of: "_", with: "-")
            return candidate == requested || candidate.split(separator: "-").first == requested.split(separator: "-").first
        }
    }

    public func accents(for language: String?) -> [String] {
        guard let language else { return [] }
        return accentsByLanguage[language] ?? accentsByLanguage.first {
            $0.key.split(separator: "-").first == language.split(separator: "-").first
        }?.value ?? []
    }
}

public enum SpeechProviderID: String, Codable, Sendable {
    case system
    case local
}

public enum SpeechProviderSelection {
    public static func select(voice: VoiceSelection, language: String?,
                              system: CapabilityProfile, local: CapabilityProfile?,
                              localIsReady: Bool) -> SpeechProviderID? {
        switch voice {
        case .systemDefault:
            guard system.status(for: .speechGeneration) == .supported,
                  system.supports(language: language) else { return nil }
            return .system
        case .saved:
            guard localIsReady, let local,
                  local.status(for: .speechGeneration) == .supported,
                  local.status(for: .voiceCloning) == .supported,
                  local.supports(language: language) else { return nil }
            return .local
        }
    }
}

public enum SpeechResult: Equatable, Sendable {
    case unsupported(VoiceCapability)
    case audio(AudioAsset, approximation: String?)
    case renderedFile(URL, duration: TimeInterval, approximation: String?)
    case failure(String)
}

public protocol SpeechProvider: Sendable {
    var id: SpeechProviderID { get }
    var capabilities: CapabilityProfile { get }
    func generate(_ request: VoiceRequest, voice: VoiceAsset?, referenceAudioURL: URL?) async -> SpeechResult
}

/// The install seam is local to the app shell; provider installation is not part of a speech request.
public protocol InstallableSpeechProvider: SpeechProvider {
    var installedResourceURL: URL { get }
    func installPack(at folder: URL) async throws -> CapabilityProfile
}

public struct UnavailableSpeechProvider: SpeechProvider {
    public let id: SpeechProviderID = .local
    public let capabilities = CapabilityProfile()

    public init() { }

    public func generate(_ request: VoiceRequest, voice: VoiceAsset?, referenceAudioURL: URL?) async -> SpeechResult {
        .unsupported(.speechGeneration)
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
            return "Local speech is not available right now."
        case .invalidRendererPack:
            return "This local speech component is invalid or incompatible."
        }
    }
}
