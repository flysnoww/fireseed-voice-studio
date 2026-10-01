import Combine
import Foundation
import UIKit

enum DiagnosticStage: String, CaseIterable, Sendable {
    case packValidation
    case packImport
    case runtimeLoad
    case voicePrepare
    case requestBuild
    case synthesis
    case dsp
    case output
}

enum DiagnosticStageState: String, Sendable {
    case idle
    case running
    case success
    case failed
}

enum VoicePrepareStateLabel: String, Codable {
    case idle
    case running
    case success
    case failed
    case interrupted
}

private struct VoicePrepareBreadcrumb: Codable {
    var state: VoicePrepareStateLabel
    var operation: String
    var timestamp: Date
    var provider: String
    var renderer: String
    var voiceID: String
    var referenceFormat: String
    var runtimeLoaded: Bool
    var memoryWarningCount: Int
    var physicalFootprintMB: Int?
}

struct DiagnosticStageResult: Sendable {
    let stage: DiagnosticStage
    let state: DiagnosticStageState
    let durationMilliseconds: Int?
    let errorDomain: String?
    let errorCode: Int?
    let friendlyError: String?
    let underlyingError: String?
    let operation: String?
    let file: String?
    let expected: String?
    let actual: String?
}

struct VoiceStudioDiagnosticSnapshot: Sendable {
    var voiceSource = "System Voice"
    var systemVoiceIdentifier: String?
    var systemVoiceQuality: Int?
    var openVoiceLoadMilliseconds: Int?
    var embeddingPrepareMilliseconds: Int?
    var conversionMilliseconds: Int?
    var provider = "System"
    var pack = "none"
    var packID: String?
    var packFilesFound: [String] = []
    var rendererID: String?
    var runtime = "not loaded"
    var rendererLoadDurationMilliseconds: Int?
    var rendererGenerationDurationMilliseconds: Int?
    var runtimeModelLocation: String?
    var backend = "System"
    var voice = "system"
    var reference = "none"
    var language = "unknown"
    var accent: String?
    var request = "invalid"
    var generation = "idle"
    var outputFileName: String?
    var outputDuration: Double?
    var generationDurationMilliseconds: Int?
    var realTimeFactor: Double?
    var voicePrepare = VoicePrepareStateLabel.idle.rawValue
    var voicePrepareOperation = "none"
    var voicePrepareContext = "none"
    var previousSession = "none"
    var memoryWarningCount = 0
    var physicalFootprintMB: Int?
}

@MainActor
final class VoiceStudioDiagnostics: ObservableObject {
    static func physicalFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
    }
    @Published private(set) var snapshot = VoiceStudioDiagnosticSnapshot()
    @Published private(set) var stages: [DiagnosticStageResult] = []
    private let breadcrumbDefaults: UserDefaults
    private let breadcrumbKey: String

    init(defaults: UserDefaults = .standard, breadcrumbKey: String = "voicePrepareBreadcrumb") {
        breadcrumbDefaults = defaults
        self.breadcrumbKey = breadcrumbKey
        if var breadcrumb = Self.loadBreadcrumb(defaults: defaults, key: breadcrumbKey),
           breadcrumb.state == .running {
            breadcrumb.state = .interrupted
            Self.saveBreadcrumb(breadcrumb, defaults: defaults, key: breadcrumbKey)
            snapshot.voicePrepare = VoicePrepareStateLabel.interrupted.rawValue
            snapshot.voicePrepareOperation = breadcrumb.operation
            snapshot.voicePrepareContext = Self.context(for: breadcrumb)
            snapshot.previousSession = "Interrupted during voicePrepare · \(breadcrumb.operation)"
            snapshot.memoryWarningCount = breadcrumb.memoryWarningCount
            snapshot.physicalFootprintMB = breadcrumb.physicalFootprintMB
            set(DiagnosticStageResult(stage: .voicePrepare, state: .failed,
                                      durationMilliseconds: nil, errorDomain: nil, errorCode: nil,
                                      friendlyError: nil, underlyingError: nil,
                                      operation: breadcrumb.operation, file: nil,
                                      expected: nil, actual: "Previous session ended during voicePrepare"))
        } else if let breadcrumb = Self.loadBreadcrumb(defaults: defaults, key: breadcrumbKey) {
            snapshot.voicePrepare = breadcrumb.state.rawValue
            snapshot.voicePrepareOperation = breadcrumb.operation
            snapshot.voicePrepareContext = Self.context(for: breadcrumb)
            snapshot.memoryWarningCount = breadcrumb.memoryWarningCount
            snapshot.physicalFootprintMB = breadcrumb.physicalFootprintMB
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recordMemoryWarning() }
        }
    }

    func update(_ change: (inout VoiceStudioDiagnosticSnapshot) -> Void) {
        change(&snapshot)
    }

    func start(_ stage: DiagnosticStage) {
        set(DiagnosticStageResult(stage: stage, state: .running, durationMilliseconds: nil,
                                  errorDomain: nil, errorCode: nil,
                                  friendlyError: nil, underlyingError: nil,
                                  operation: nil, file: nil, expected: nil, actual: nil))
    }

    func beginVoicePrepare(provider: String, renderer: String, voiceID: UUID,
                           referenceFormat: String, runtimeLoaded: Bool,
                           physicalFootprintMB: Int?) {
        let breadcrumb = VoicePrepareBreadcrumb(
            state: .running, operation: "resolveProvider", timestamp: Date(),
            provider: provider, renderer: renderer,
            voiceID: String(voiceID.uuidString.prefix(8)),
            referenceFormat: referenceFormat, runtimeLoaded: runtimeLoaded,
            memoryWarningCount: snapshot.memoryWarningCount,
            physicalFootprintMB: physicalFootprintMB)
        Self.saveBreadcrumb(breadcrumb, defaults: breadcrumbDefaults, key: breadcrumbKey)
        snapshot.voicePrepare = VoicePrepareStateLabel.running.rawValue
        snapshot.voicePrepareOperation = breadcrumb.operation
        snapshot.voicePrepareContext = Self.context(for: breadcrumb)
        snapshot.previousSession = "none"
        snapshot.physicalFootprintMB = physicalFootprintMB
    }

    func updateVoicePrepareOperation(_ operation: String, runtimeLoaded: Bool? = nil,
                                     referenceFormat: String? = nil, physicalFootprintMB: Int? = nil) {
        guard var breadcrumb = Self.loadBreadcrumb(defaults: breadcrumbDefaults, key: breadcrumbKey) else { return }
        breadcrumb.operation = operation
        if let runtimeLoaded { breadcrumb.runtimeLoaded = runtimeLoaded }
        if let referenceFormat { breadcrumb.referenceFormat = referenceFormat }
        breadcrumb.physicalFootprintMB = physicalFootprintMB ?? breadcrumb.physicalFootprintMB
        Self.saveBreadcrumb(breadcrumb, defaults: breadcrumbDefaults, key: breadcrumbKey)
        snapshot.voicePrepareOperation = operation
        snapshot.voicePrepareContext = Self.context(for: breadcrumb)
        snapshot.physicalFootprintMB = breadcrumb.physicalFootprintMB
    }

    func finishVoicePrepare(_ state: VoicePrepareStateLabel, physicalFootprintMB: Int? = nil) {
        guard var breadcrumb = Self.loadBreadcrumb(defaults: breadcrumbDefaults, key: breadcrumbKey) else { return }
        breadcrumb.state = state
        breadcrumb.timestamp = Date()
        breadcrumb.physicalFootprintMB = physicalFootprintMB ?? breadcrumb.physicalFootprintMB
        Self.saveBreadcrumb(breadcrumb, defaults: breadcrumbDefaults, key: breadcrumbKey)
        snapshot.voicePrepare = state.rawValue
        snapshot.voicePrepareOperation = breadcrumb.operation
        snapshot.voicePrepareContext = Self.context(for: breadcrumb)
        snapshot.physicalFootprintMB = breadcrumb.physicalFootprintMB
    }

    private func recordMemoryWarning() {
        snapshot.memoryWarningCount += 1
        guard var breadcrumb = Self.loadBreadcrumb(defaults: breadcrumbDefaults, key: breadcrumbKey) else { return }
        breadcrumb.memoryWarningCount = snapshot.memoryWarningCount
        Self.saveBreadcrumb(breadcrumb, defaults: breadcrumbDefaults, key: breadcrumbKey)
    }

    func finish(_ stage: DiagnosticStage, startedAt: TimeInterval,
                error: Error? = nil, friendlyError: String? = nil,
                operation: String? = nil, file: String? = nil,
                expected: String? = nil, actual: String? = nil) {
        let nsError = error as NSError?
        let safeUnderlying = nsError.map { Self.redact($0.localizedDescription) }
        set(DiagnosticStageResult(stage: stage, state: error == nil ? .success : .failed,
                                  durationMilliseconds: max(0, Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)),
                                  errorDomain: nsError?.domain, errorCode: nsError?.code,
                                  friendlyError: friendlyError, underlyingError: safeUnderlying,
                                  operation: operation, file: file.map(Self.safePackPath),
                                  expected: expected.map(Self.redact), actual: actual.map(Self.redact)))
    }

    func clear() {
        stages.removeAll()
        snapshot.generation = "idle"
        snapshot.request = "invalid"
        snapshot.outputFileName = nil
        snapshot.outputDuration = nil
        snapshot.rendererLoadDurationMilliseconds = nil
        snapshot.rendererGenerationDurationMilliseconds = nil
        snapshot.generationDurationMilliseconds = nil
        snapshot.realTimeFactor = nil
    }

    func exportText() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let date = ISO8601DateFormatter().string(from: Date())
        var lines = [
            "Voice Studio Diagnostics",
            "App version: \(version)",
            "Build: \(build)",
            "Timestamp: \(date)",
            "Provider: \(snapshot.provider)",
            "Voice source: \(snapshot.voiceSource)",
            "System identifier: \(snapshot.systemVoiceIdentifier ?? "--")",
            "System quality: \(snapshot.systemVoiceQuality.map(String.init) ?? "--")",
            "OpenVoice load: \(snapshot.openVoiceLoadMilliseconds.map(String.init) ?? "--") ms",
            "Embedding prepare: \(snapshot.embeddingPrepareMilliseconds.map(String.init) ?? "--") ms",
            "Conversion: \(snapshot.conversionMilliseconds.map(String.init) ?? "--") ms",
            "Pack: \(snapshot.pack)",
            "Pack ID: \(snapshot.packID ?? "--")",
            "Renderer ID: \(snapshot.rendererID ?? "--")",
            "Required files: \(snapshot.packFilesFound.isEmpty ? "--" : snapshot.packFilesFound.joined(separator: ", "))",
            "Runtime: \(snapshot.runtime)",
            "Renderer load: \(snapshot.rendererLoadDurationMilliseconds.map { "\($0) ms" } ?? "--")",
            "Model folder: \(snapshot.runtimeModelLocation ?? "--")",
            "Backend: \(snapshot.backend)",
            "Voice: \(snapshot.voice)",
            "Reference: \(snapshot.reference)",
            "Language: \(snapshot.language)",
            "Accent: \(snapshot.accent ?? "--")",
            "Request: \(snapshot.request)",
            "Generate: \(snapshot.generation)",
            "Voice prepare: \(snapshot.voicePrepare)",
            "Voice prepare operation: \(snapshot.voicePrepareOperation)",
            "Voice prepare context: \(snapshot.voicePrepareContext)",
            "Previous session: \(snapshot.previousSession)",
            "Memory warnings: \(snapshot.memoryWarningCount)",
            "Process physical footprint: \(snapshot.physicalFootprintMB.map { "\($0) MB" } ?? "--")",
            "Generate time: \(snapshot.generationDurationMilliseconds.map { "\($0) ms" } ?? "--")",
            "Renderer inference: \(snapshot.rendererGenerationDurationMilliseconds.map { "\($0) ms" } ?? "--")",
            "Output: \(snapshot.outputFileName.map { "\($0) · \(snapshot.outputDuration.map { String(format: "%.2f s", $0) } ?? "duration unknown")" } ?? "none")",
            "RTF: \(snapshot.realTimeFactor.map { String(format: "%.2f", $0) } ?? "--")",
            "Pipeline:"
        ]
        for stage in stages {
            let duration = stage.durationMilliseconds.map { " · \($0) ms" } ?? ""
            lines.append("\(stage.stage.rawValue): \(stage.state.rawValue)\(duration)")
            if let error = stage.friendlyError { lines.append("  Friendly error: \(Self.redact(error))") }
            if let domain = stage.errorDomain { lines.append("  Error domain: \(domain)") }
            if let code = stage.errorCode { lines.append("  Error code: \(code)") }
            if let raw = stage.underlyingError { lines.append("  Raw error: \(Self.redact(raw))") }
            if let operation = stage.operation { lines.append("  Operation: \(operation)") }
            if let file = stage.file { lines.append("  File: \(file)") }
            if let expected = stage.expected { lines.append("  Expected: \(expected)") }
            if let actual = stage.actual { lines.append("  Actual: \(actual)") }
        }
        return lines.joined(separator: "\n")
    }

    private func set(_ result: DiagnosticStageResult) {
        if let index = stages.firstIndex(where: { $0.stage == result.stage }) {
            stages[index] = result
        } else {
            stages.append(result)
        }
        stages.sort { DiagnosticStage.allCases.firstIndex(of: $0.stage)! < DiagnosticStage.allCases.firstIndex(of: $1.stage)! }
    }

    private static func loadBreadcrumb(defaults: UserDefaults, key: String) -> VoicePrepareBreadcrumb? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(VoicePrepareBreadcrumb.self, from: data)
    }

    private static func saveBreadcrumb(_ breadcrumb: VoicePrepareBreadcrumb,
                                       defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(breadcrumb) else { return }
        defaults.set(data, forKey: key)
    }

    private static func context(for breadcrumb: VoicePrepareBreadcrumb) -> String {
        "provider=\(breadcrumb.provider) · renderer=\(breadcrumb.renderer) · voice=\(breadcrumb.voiceID) · " +
        "reference=\(breadcrumb.referenceFormat) · runtimeLoaded=\(breadcrumb.runtimeLoaded) · " +
        "started=\(ISO8601DateFormatter().string(from: breadcrumb.timestamp))"
    }

    private static func redact(_ text: String) -> String {
        let patterns = [
            #"[A-Za-z]:[\\/][^\r\n,;]+"#,
            #"/[^\r\n,;]+"#
        ]
        return patterns.reduce(text) { result, pattern in
            result.replacingOccurrences(of: pattern, with: "[private path]", options: .regularExpression)
        }
    }

    private static func safePackPath(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !normalized.contains(":"),
              !normalized.split(separator: "/").contains("..") else {
            return normalized.split(separator: "/").last.map(String.init) ?? "unknown"
        }
        return normalized
    }
}
