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

public enum GeneratedAudioVoiceSource: Codable, Equatable, Sendable {
    case savedVoice(UUID)
    case systemVoice(String?)
    case tinyLocalVoice(String?)
}

public enum GeneratedAudioOrdering {
    public static let pageSize = 10

    public static func newestFirst(_ assets: [AudioAsset]) -> [AudioAsset] {
        assets.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public static func pageCount(for count: Int) -> Int { max(1, (count + pageSize - 1) / pageSize) }

    public static func validPage(_ page: Int, count: Int) -> Int {
        min(max(0, page), pageCount(for: count) - 1)
    }

    public static func page(_ assets: [AudioAsset], index: Int) -> [AudioAsset] {
        let start = validPage(index, count: assets.count) * pageSize
        return Array(assets.dropFirst(start).prefix(pageSize))
    }
}

public enum AudioGenerationKind: String, Codable, Sendable {
    case normal, imitationSameContent, imitationNewText
}

/// Local performance provenance only. No transcript, model tensors, or cloud identity.
public struct PerformanceReference: Equatable, Sendable {
    public let audio: AudioAsset
    public init(audio: AudioAsset) { self.audio = audio }
}

public struct AudioAsset: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    /// A generated file name relative to the managed audio store, never an arbitrary URL.
    public let fileName: String
    public let duration: TimeInterval
    public let createdAt: Date
    public let sourceVoiceID: UUID?
    public let sourceVoice: GeneratedAudioVoiceSource?
    public let language: String?
    public let text: String?
    public let displayName: String
    public let isFavorite: Bool
    public let generationKind: AudioGenerationKind
    public let referencePerformanceID: UUID?
    public let persistenceState: AudioPersistenceState

    public init(id: UUID = UUID(), fileName: String, duration: TimeInterval, createdAt: Date = Date(),
                sourceVoiceID: UUID? = nil, sourceVoice: GeneratedAudioVoiceSource? = nil,
                language: String? = nil, text: String? = nil, displayName: String? = nil,
                isFavorite: Bool = false, generationKind: AudioGenerationKind = .normal,
                referencePerformanceID: UUID? = nil,
                persistenceState: AudioPersistenceState = .temporary) {
        self.id = id
        self.fileName = fileName
        self.duration = duration
        self.createdAt = createdAt
        self.sourceVoiceID = sourceVoiceID
        self.sourceVoice = sourceVoice ?? sourceVoiceID.map(GeneratedAudioVoiceSource.savedVoice)
        self.language = language
        self.text = text
        let suggested = text?.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = displayName ?? suggested.flatMap { $0.isEmpty ? nil : String($0.prefix(48)) } ?? "Generated Audio"
        self.isFavorite = isFavorite
        self.generationKind = generationKind
        self.referencePerformanceID = referencePerformanceID
        self.persistenceState = persistenceState
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, duration, createdAt, sourceVoiceID, sourceVoice, language, text, displayName, isFavorite, persistenceState, generationKind, referencePerformanceID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let fileName = try values.decode(String.self, forKey: .fileName)
        let duration = try values.decode(TimeInterval.self, forKey: .duration)
        let createdAt = try values.decode(Date.self, forKey: .createdAt)
        let sourceVoiceID = try values.decodeIfPresent(UUID.self, forKey: .sourceVoiceID)
        let sourceVoice = try values.decodeIfPresent(GeneratedAudioVoiceSource.self, forKey: .sourceVoice)
        let language = try values.decodeIfPresent(String.self, forKey: .language)
        let text = try values.decodeIfPresent(String.self, forKey: .text)
        let displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
        let isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        let persistenceState = try values.decode(AudioPersistenceState.self, forKey: .persistenceState)
        self.init(id: id, fileName: fileName, duration: duration, createdAt: createdAt,
                  sourceVoiceID: sourceVoiceID, sourceVoice: sourceVoice, language: language,
                  text: text, displayName: displayName, isFavorite: isFavorite,
                  generationKind: try values.decodeIfPresent(AudioGenerationKind.self, forKey: .generationKind) ?? .normal,
                  referencePerformanceID: try values.decodeIfPresent(UUID.self, forKey: .referencePerformanceID),
                  persistenceState: persistenceState)
    }
}

public enum VoiceSourceType: String, Codable, Sendable {
    case record
    case imported
    case random
    case builtIn
}

public enum VoiceRenderingPreference: String, Codable, Sendable {
    case automatic, advancedLocal
}

public struct VoiceProfile: Codable, Equatable, Sendable {
    public var speed: Double
    public var pitch: Double
    public var language: String
    public var accent: String?
    public var renderingPreference: VoiceRenderingPreference
    public init(speed: Double = 1, pitch: Double = 0, language: String = "en",
                accent: String? = nil, renderingPreference: VoiceRenderingPreference = .automatic) {
        self.speed = speed; self.pitch = pitch; self.language = language
        self.accent = accent; self.renderingPreference = renderingPreference
    }
    public var isValid: Bool {
        speed.isFinite && (0.5...2).contains(speed) && pitch.isFinite && (-1200...1200).contains(pitch) && !language.isEmpty
    }
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
    public let isFavorite: Bool

    /// Voices are created as part of the save action; keep this computed to preserve the stored schema.
    public let profile: VoiceProfile
    public var savedAt: Date { createdAt }

    public init(id: UUID = UUID(), name: String, sourceType: VoiceSourceType, referenceAudio: AudioAsset,
                languageHint: String? = nil, defaultAccent: String? = nil,
                defaultAttributes: [String: String] = [:], createdAt: Date = Date(), updatedAt: Date = Date(),
                isFavorite: Bool = false, profile: VoiceProfile? = nil) {
        self.id = id
        self.name = name
        self.sourceType = sourceType
        self.referenceAudio = referenceAudio
        self.languageHint = languageHint
        self.defaultAccent = defaultAccent
        self.defaultAttributes = defaultAttributes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isFavorite = isFavorite
        self.profile = profile ?? VoiceProfile(language: languageHint ?? "en", accent: defaultAccent)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourceType, referenceAudio, languageHint, defaultAccent, defaultAttributes, createdAt, updatedAt, isFavorite, profile
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id),
                  name: try values.decode(String.self, forKey: .name),
                  sourceType: try values.decode(VoiceSourceType.self, forKey: .sourceType),
                  referenceAudio: try values.decode(AudioAsset.self, forKey: .referenceAudio),
                  languageHint: try values.decodeIfPresent(String.self, forKey: .languageHint),
                  defaultAccent: try values.decodeIfPresent(String.self, forKey: .defaultAccent),
                  defaultAttributes: try values.decodeIfPresent([String: String].self, forKey: .defaultAttributes) ?? [:],
                  createdAt: try values.decode(Date.self, forKey: .createdAt),
                  updatedAt: try values.decode(Date.self, forKey: .updatedAt),
                  isFavorite: try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
                  profile: try values.decodeIfPresent(VoiceProfile.self, forKey: .profile))
    }

    public func updating(name: String? = nil, isFavorite: Bool? = nil, profile: VoiceProfile? = nil) -> VoiceAsset {
        VoiceAsset(id: id, name: name ?? self.name, sourceType: sourceType, referenceAudio: referenceAudio,
                   languageHint: languageHint, defaultAccent: defaultAccent, defaultAttributes: defaultAttributes,
                   createdAt: createdAt, updatedAt: Date(), isFavorite: isFavorite ?? self.isFavorite,
                   profile: profile ?? self.profile)
    }
}

public enum VoiceSelection: Codable, Equatable, Hashable, Sendable {
    case saved(UUID)
    case systemDefault
    case systemVoice(String)
    case tinyLocal

    public var savedVoiceID: UUID? {
        guard case .saved(let id) = self else { return nil }
        return id
    }
}

public enum VoiceShape: String, Codable, CaseIterable, Sendable {
    case brightness, clarity, softness
    // Legacy keys remain decodable for saved requests, but are not advertised
    // until an implementation can support them safely.
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
    case voiceConversion
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
    case tinyLocal
    case local
    case voiceConverter
}

public enum SpeechProviderSelection {
    public static func select(voice: VoiceSelection, language: String?,
                              system: CapabilityProfile, local: CapabilityProfile?,
                              localIsReady: Bool, tinyLocal: CapabilityProfile? = nil,
                              tinyLocalIsReady: Bool = true,
                              voiceConverter: CapabilityProfile? = nil,
                              voiceConverterIsReady: Bool = false,
                              useVoiceConverter: Bool = false) -> SpeechProviderID? {
        switch voice {
        case .systemDefault:
            guard system.status(for: .speechGeneration) == .supported,
                  system.supports(language: language) else { return nil }
            return .system
        case .systemVoice:
            guard system.status(for: .speechGeneration) == .supported,
                  system.supports(language: language) else { return nil }
            return .system
        case .tinyLocal:
            guard tinyLocalIsReady, let tinyLocal,
                  tinyLocal.status(for: .speechGeneration) == .supported,
                  tinyLocal.supports(language: language) else { return nil }
            return .tinyLocal
        case .saved:
            if useVoiceConverter {
                guard voiceConverterIsReady, let voiceConverter,
                      voiceConverter.status(for: .voiceConversion) == .supported,
                      voiceConverter.supports(language: language),
                      system.status(for: .speechGeneration) == .supported,
                      system.supports(language: language) else { return nil }
                return .voiceConverter
            }
            guard localIsReady, let local,
                  local.status(for: .speechGeneration) == .supported,
                  local.status(for: .voiceCloning) == .supported,
                  local.supports(language: language) else { return nil }
            return .local
        }
    }
}

public enum VoiceCapabilityVisibility {
    public static func visibleShaping(in profile: CapabilityProfile) -> [VoiceShape] {
        VoiceShape.allCases.filter { profile.shaping[$0] == .supported || profile.shaping[$0] == .approximate }
    }

    public static func visibleExpressions(in profile: CapabilityProfile) -> [VoiceExpression] {
        VoiceExpression.allCases.filter { profile.expressions[$0] == .supported || profile.expressions[$0] == .approximate }
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
    case assetIsReferenced
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
        case .assetIsReferenced:
            return "This audio is still used by another saved asset."
        case .recordingFailed:
            return "Recording stopped before a valid audio file was created."
        case .rendererUnavailable:
            return "Local speech is not available right now."
        case .invalidRendererPack:
            return "This local speech component is invalid or incompatible."
        }
    }
}
