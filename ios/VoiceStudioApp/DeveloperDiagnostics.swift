import Combine
import Foundation

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
}

@MainActor
final class VoiceStudioDiagnostics: ObservableObject {
    @Published private(set) var snapshot = VoiceStudioDiagnosticSnapshot()
    @Published private(set) var stages: [DiagnosticStageResult] = []

    func update(_ change: (inout VoiceStudioDiagnosticSnapshot) -> Void) {
        change(&snapshot)
    }

    func start(_ stage: DiagnosticStage) {
        set(DiagnosticStageResult(stage: stage, state: .running, durationMilliseconds: nil,
                                  errorDomain: nil, errorCode: nil,
                                  friendlyError: nil, underlyingError: nil,
                                  operation: nil, file: nil, expected: nil, actual: nil))
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
