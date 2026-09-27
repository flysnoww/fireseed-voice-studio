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

enum AppSkin: String, CaseIterable, Identifiable {
    case frost
    case warm

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .frost: "Frosted Glass"
        case .warm: "Warm Glass"
        }
    }

    var accent: Color {
        switch self {
        case .frost: Color(red: 0.29, green: 0.45, blue: 0.82)
        case .warm: Color(red: 0.68, green: 0.36, blue: 0.25)
        }
    }

    var backdrop: [Color] {
        switch self {
        case .frost: [Color(red: 0.86, green: 0.91, blue: 0.98), Color(red: 0.93, green: 0.90, blue: 0.97)]
        case .warm: [Color(red: 0.98, green: 0.91, blue: 0.84), Color(red: 0.95, green: 0.88, blue: 0.83)]
        }
    }

    var material: Material {
        switch self {
        case .frost: .ultraThinMaterial
        case .warm: .regularMaterial
        }
    }
}

@MainActor
final class AppAppearancePreference: ObservableObject {
    @Published private(set) var skin: AppSkin
    @Published private(set) var backgroundImageURL: URL?

    private let defaults: UserDefaults
    private let skinKey: String
    private let backgroundKey: String
    private let appearanceDirectory: URL

    init(defaults: UserDefaults = .standard,
         skinKey: String = "appSkin",
         backgroundKey: String = "appBackgroundImagePath",
         appearanceDirectory: URL? = nil) {
        self.defaults = defaults
        self.skinKey = skinKey
        self.backgroundKey = backgroundKey
        self.appearanceDirectory = appearanceDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceStudio/Appearance", isDirectory: true)
        skin = defaults.string(forKey: skinKey).flatMap(AppSkin.init(rawValue:)) ?? .frost
        if let path = defaults.string(forKey: backgroundKey), FileManager.default.fileExists(atPath: path) {
            backgroundImageURL = URL(fileURLWithPath: path)
        }
    }

    func setSkin(_ skin: AppSkin) {
        defaults.set(skin.rawValue, forKey: skinKey)
        self.skin = skin
    }

    func saveBackgroundImage(_ data: Data) throws {
        try FileManager.default.createDirectory(at: appearanceDirectory, withIntermediateDirectories: true)
        let destination = appearanceDirectory.appendingPathComponent("background.jpg")
        try data.write(to: destination, options: .atomic)
        defaults.set(destination.path, forKey: backgroundKey)
        backgroundImageURL = destination
    }

    func clearBackgroundImage() {
        if let backgroundImageURL,
           backgroundImageURL.deletingLastPathComponent().standardizedFileURL == appearanceDirectory.standardizedFileURL {
            try? FileManager.default.removeItem(at: backgroundImageURL)
        }
        defaults.removeObject(forKey: backgroundKey)
        backgroundImageURL = nil
    }
}
