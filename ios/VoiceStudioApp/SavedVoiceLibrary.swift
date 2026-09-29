import Foundation
import VoiceStudioCore

enum SavedVoiceFilter: String, CaseIterable, Identifiable {
    case time
    case imported
    case recorded

    var id: String { rawValue }

    var sourceType: VoiceSourceType? {
        switch self {
        case .time: nil
        case .imported: .imported
        case .recorded: .record
        }
    }
}

enum SavedVoiceLibrary {
    static let pageSize = 8

    static func voices(_ voices: [VoiceAsset], matching filter: SavedVoiceFilter) -> [VoiceAsset] {
        voices
            .filter { voice in
                guard let sourceType = filter.sourceType else { return true }
                return voice.sourceType == sourceType
            }
            .sorted {
                if $0.savedAt != $1.savedAt { return $0.savedAt > $1.savedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    static func pageCount(for voiceCount: Int) -> Int {
        max(1, (voiceCount + pageSize - 1) / pageSize)
    }

    static func validPage(_ page: Int, voiceCount: Int) -> Int {
        min(max(0, page), pageCount(for: voiceCount) - 1)
    }

    static func page(_ voices: [VoiceAsset], index: Int) -> [VoiceAsset] {
        let start = min(max(0, index), pageCount(for: voices.count) - 1) * pageSize
        return Array(voices.dropFirst(start).prefix(pageSize))
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.isFinite ? duration.rounded(.down) : 0))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

enum GeneratedAudioLibrary {
    static let pageSize = GeneratedAudioOrdering.pageSize
    static func assets(_ assets: [AudioAsset]) -> [AudioAsset] { GeneratedAudioOrdering.newestFirst(assets) }
    static func pageCount(for count: Int) -> Int { GeneratedAudioOrdering.pageCount(for: count) }
    static func validPage(_ page: Int, count: Int) -> Int { GeneratedAudioOrdering.validPage(page, count: count) }
    static func page(_ assets: [AudioAsset], index: Int) -> [AudioAsset] { GeneratedAudioOrdering.page(assets, index: index) }
}
