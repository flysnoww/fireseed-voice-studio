import Combine
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @Published private(set) var backgroundDiagnostics: [BackgroundImportDiagnostic] = []

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

    func saveBackgroundImage(_ data: Data, sourceContentType: String? = nil, requestID: UUID? = nil) throws {
        let result: BackgroundImageNormalizer.Result
        do {
            result = try BackgroundImageNormalizer.normalizeWithReport(data, sourceContentType: sourceContentType) {
                stage, succeeded, metadata, error, duration in
                recordBackgroundDiagnostic(stage: stage, succeeded: succeeded, sourceContentType: sourceContentType,
                                           metadata: metadata, error: error, durationMilliseconds: duration,
                                           requestID: requestID)
            }
        } catch {
            if backgroundDiagnostics.last?.succeeded != false {
                recordBackgroundDiagnostic(stage: (error as? BackgroundImageNormalizer.Failure)?.stage ?? "decodeImage",
                                           succeeded: false, sourceContentType: sourceContentType,
                                           metadata: nil, error: error, requestID: requestID)
            }
            throw error
        }
        let destination = appearanceDirectory.appendingPathComponent("background.jpg")
        do {
            try FileManager.default.createDirectory(at: appearanceDirectory, withIntermediateDirectories: true)
            try result.data.write(to: destination, options: .atomic)
        } catch {
            recordBackgroundDiagnostic(stage: "persist", succeeded: false, sourceContentType: sourceContentType,
                                       metadata: result.metadata, error: error, requestID: requestID)
            throw error
        }
        recordBackgroundDiagnostic(stage: "reload", succeeded: true, sourceContentType: sourceContentType,
                                   metadata: result.metadata, requestID: requestID)
        guard UIImage(contentsOfFile: destination.path) != nil else {
            let error = BackgroundImageNormalizer.Failure.decode("Managed background could not be decoded for display")
            recordBackgroundDiagnostic(stage: "display", succeeded: false, sourceContentType: sourceContentType,
                                       metadata: result.metadata, error: error, requestID: requestID)
            throw error
        }
        defaults.set(destination.path, forKey: backgroundKey)
        backgroundImageURL = destination
        recordBackgroundDiagnostic(stage: "display", succeeded: true, sourceContentType: sourceContentType,
                                   metadata: result.metadata, requestID: requestID)
        recordBackgroundDiagnostic(stage: "persist", succeeded: true, sourceContentType: sourceContentType,
                                   metadata: result.metadata, requestID: requestID)
    }

    func recordBackgroundDiagnostic(stage: String, succeeded: Bool, sourceContentType: String? = nil,
                                    metadata: BackgroundImageMetadata? = nil, error: Error? = nil,
                                    durationMilliseconds: Int? = nil, requestID: UUID? = nil) {
        let nsError = error as NSError?
        let record = BackgroundImportDiagnostic(
            stage: stage, succeeded: succeeded, durationMilliseconds: durationMilliseconds, requestID: requestID,
            contentType: sourceContentType ?? metadata?.contentType,
            fileExtension: (sourceContentType.flatMap(UTType.init)?.preferredFilenameExtension) ?? metadata?.fileExtension,
            mimeType: sourceContentType.flatMap(UTType.init)?.preferredMIMEType ?? metadata?.mimeType,
            sourceByteSize: metadata?.sourceByteSize,
            normalizedByteSize: metadata?.normalizedByteSize,
            pixelWidth: metadata?.pixelWidth, pixelHeight: metadata?.pixelHeight,
            normalizedPixelWidth: metadata?.normalizedPixelWidth,
            normalizedPixelHeight: metadata?.normalizedPixelHeight,
            orientation: metadata?.orientation, colorSpace: metadata?.colorSpace,
            outputColorSpace: metadata?.outputColorSpace,
            hdrOrWideColor: metadata?.hdrOrWideColor, outputFormat: metadata?.outputFormat,
            errorDomain: nsError?.domain, errorCode: nsError?.code,
            errorMessage: error.map { BackgroundImportDiagnostic.safeMessage($0.localizedDescription) })
        backgroundDiagnostics.append(record)
        if backgroundDiagnostics.count > 40 { backgroundDiagnostics.removeFirst(backgroundDiagnostics.count - 40) }
    }

    var backgroundDiagnosticsText: String {
        guard !backgroundDiagnostics.isEmpty else { return "No background imports recorded." }
        return backgroundDiagnostics.map { $0.exportLine }.joined(separator: "\n")
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

struct BackgroundImageMetadata {
    var contentType: String?
    var fileExtension: String?
    var mimeType: String?
    var sourceByteSize: Int?
    var normalizedByteSize: Int?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var normalizedPixelWidth: Int?
    var normalizedPixelHeight: Int?
    var orientation: Int?
    var colorSpace: String?
    var outputColorSpace: String?
    var hdrOrWideColor: Bool?
    var outputFormat: String?
}

struct BackgroundImportDiagnostic {
    let stage: String
    let succeeded: Bool
    let durationMilliseconds: Int?
    let requestID: UUID?
    let contentType: String?
    let fileExtension: String?
    let mimeType: String?
    let sourceByteSize: Int?
    let normalizedByteSize: Int?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let normalizedPixelWidth: Int?
    let normalizedPixelHeight: Int?
    let orientation: Int?
    let colorSpace: String?
    let outputColorSpace: String?
    let hdrOrWideColor: Bool?
    let outputFormat: String?
    let errorDomain: String?
    let errorCode: Int?
    let errorMessage: String?

    var exportLine: String {
        var values = ["\(stage): \(succeeded ? "success" : "failed")"]
        if let requestID { values.append("request=\(requestID.uuidString.prefix(8))") }
        if let durationMilliseconds { values.append("\(durationMilliseconds) ms") }
        if let contentType { values.append("type=\(contentType)") }
        if let fileExtension { values.append("ext=\(fileExtension)") }
        if let mimeType { values.append("mime=\(mimeType)") }
        if let pixelWidth, let pixelHeight { values.append("pixels=\(pixelWidth)x\(pixelHeight)") }
        if let normalizedPixelWidth, let normalizedPixelHeight {
            values.append("normalizedPixels=\(normalizedPixelWidth)x\(normalizedPixelHeight)")
        }
        if let orientation { values.append("orientation=\(orientation)") }
        if let colorSpace { values.append("color=\(colorSpace)") }
        if let outputColorSpace { values.append("outputColor=\(outputColorSpace)") }
        if let hdrOrWideColor { values.append("HDR/wide-color=\(hdrOrWideColor)") }
        if let sourceByteSize { values.append("source=\(sourceByteSize) bytes") }
        if let normalizedByteSize { values.append("normalized=\(normalizedByteSize) bytes") }
        if let outputFormat { values.append("output=\(outputFormat)") }
        if let errorDomain { values.append("error=\(errorDomain)/\(errorCode ?? 0)") }
        if let errorMessage { values.append("detail=\(errorMessage)") }
        return values.joined(separator: " · ")
    }

    fileprivate static func safeMessage(_ value: String) -> String {
        let patterns = [#"[A-Za-z]:[\\/][^\r\n,;]+"#, #"/[^\r\n,;]+"#]
        return patterns.reduce(value) {
            $0.replacingOccurrences(of: $1, with: "[private path]", options: .regularExpression)
        }
    }
}

enum BackgroundImageNormalizer {
    struct Result {
        let data: Data
        let metadata: BackgroundImageMetadata
    }

    enum Failure: Error {
        case decode(String)
        case normalize(String)
        case encode

        var stage: String {
            switch self {
            case .decode(_): return "decode"
            case .normalize(_): return "normalize"
            case .encode: return "encode"
            }
        }
    }

    static func normalize(_ data: Data, maxPixelSize: Int = 2560) throws -> Data {
        try normalizeWithReport(data, maxPixelSize: maxPixelSize).data
    }

    static func normalizeWithReport(
        _ data: Data,
        sourceContentType: String? = nil,
        maxPixelSize: Int = 2560,
        stageHandler: (String, Bool, BackgroundImageMetadata?, Error?, Int?) -> Void = { _, _, _, _, _ in }
    ) throws -> Result {
        var metadata = BackgroundImageMetadata(contentType: sourceContentType,
                                              fileExtension: sourceContentType.flatMap(UTType.init)?.preferredFilenameExtension,
                                              mimeType: sourceContentType.flatMap(UTType.init)?.preferredMIMEType,
                                              sourceByteSize: data.count)
        let decodeStart = ProcessInfo.processInfo.systemUptime
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            let error = Failure.decode("ImageIO could not read the selected image data")
            stageHandler("decodeImage", false, metadata, error,
                         elapsedMilliseconds(since: decodeStart))
            throw error
        }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            metadata.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int
            metadata.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int
            metadata.orientation = properties[kCGImagePropertyOrientation] as? Int
            let depth = properties[kCGImagePropertyDepth] as? Int
            let profileName = (properties[kCGImagePropertyProfileName] as? String)?.lowercased()
            if let profileName {
                if profileName.contains("p3") { metadata.colorSpace = "Display P3" }
                else if profileName.contains("hlg") { metadata.colorSpace = "HLG" }
                else if profileName.contains("pq") { metadata.colorSpace = "PQ" }
                else if profileName.contains("srgb") { metadata.colorSpace = "sRGB" }
                else { metadata.colorSpace = "Other" }
            }
            let lowerName = profileName ?? ""
            if let depth {
                metadata.hdrOrWideColor = depth > 8 || lowerName.contains("p3") ||
                    lowerName.contains("hlg") || lowerName.contains("pq")
            } else if !lowerName.isEmpty {
                metadata.hdrOrWideColor = lowerName.contains("p3") || lowerName.contains("hlg") ||
                    lowerName.contains("pq")
            }
        }
        stageHandler("decodeImage", true, metadata, nil, elapsedMilliseconds(since: decodeStart))

        let transformStart = ProcessInfo.processInfo.systemUptime
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else {
            let error = Failure.decode("ImageIO could not decode the selected image")
            stageHandler("normalizeOrientation", false, metadata, error,
                         elapsedMilliseconds(since: transformStart))
            throw error
        }
        metadata.normalizedPixelWidth = image.width
        metadata.normalizedPixelHeight = image.height
        stageHandler("normalizeOrientation", true, metadata, nil, elapsedMilliseconds(since: transformStart))
        stageHandler("resize", true, metadata, nil, elapsedMilliseconds(since: transformStart))

        let colorStart = ProcessInfo.processInfo.systemUptime
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let normalized = draw(image, in: context) else {
            let error = Failure.normalize("Could not normalize orientation or color space")
            stageHandler("normalizeColor", false, metadata, error, elapsedMilliseconds(since: colorStart))
            throw error
        }
        metadata.outputColorSpace = "sRGB"
        stageHandler("normalizeColor", true, metadata, nil, elapsedMilliseconds(since: colorStart))

        let encodeStart = ProcessInfo.processInfo.systemUptime
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            stageHandler("encodeManagedAsset", false, metadata, Failure.encode,
                         elapsedMilliseconds(since: encodeStart))
            throw Failure.encode
        }
        CGImageDestinationAddImage(destination, normalized,
                                   [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            stageHandler("encodeManagedAsset", false, metadata, Failure.encode,
                         elapsedMilliseconds(since: encodeStart))
            throw Failure.encode
        }
        metadata.normalizedByteSize = output.length
        metadata.outputFormat = UTType.jpeg.identifier
        stageHandler("encodeManagedAsset", true, metadata, nil, elapsedMilliseconds(since: encodeStart))
        return Result(data: output as Data, metadata: metadata)
    }

    private static func elapsedMilliseconds(since start: TimeInterval) -> Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
    }

    private static func draw(_ image: CGImage, in context: CGContext) -> CGImage? {
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
