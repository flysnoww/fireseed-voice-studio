import Combine
import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        }
    }

    var usesSystemLocale: Bool { self == .system }

    var displayName: LocalizedStringKey {
        switch self {
        case .system: "System Default"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }
}

@MainActor
final class AppLanguagePreference: ObservableObject {
    @Published private(set) var language: AppLanguage
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "appLanguage") {
        self.defaults = defaults
        self.key = key
        language = defaults.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func set(_ language: AppLanguage) {
        defaults.set(language.rawValue, forKey: key)
        self.language = language
    }
}
