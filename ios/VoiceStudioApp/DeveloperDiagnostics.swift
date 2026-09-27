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
}

struct VoiceStudioDiagnosticSnapshot: Sendable {
    var provider = "System"
    var pack = "none"
    var packID: String?
    var packFilesFound: [String] = []
    var runtime = "not loaded"
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
                                  friendlyError: nil, underlyingError: nil))
    }

    func finish(_ stage: DiagnosticStage, startedAt: TimeInterval,
                error: Error? = nil, friendlyError: String? = nil) {
        let nsError = error as NSError?
        let safeUnderlying = nsError.map { Self.redact($0.localizedDescription) }
        set(DiagnosticStageResult(stage: stage, state: error == nil ? .success : .failed,
                                  durationMilliseconds: max(0, Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)),
                                  errorDomain: nsError?.domain, errorCode: nsError?.code,
                                  friendlyError: friendlyError, underlyingError: safeUnderlying))
    }

    func clear() {
        stages.removeAll()
        snapshot.generation = "idle"
        snapshot.request = "invalid"
        snapshot.outputFileName = nil
        snapshot.outputDuration = nil
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
            "Required files: \(snapshot.packFilesFound.isEmpty ? "--" : snapshot.packFilesFound.joined(separator: ", "))",
            "Runtime: \(snapshot.runtime)",
            "Model folder: \(snapshot.runtimeModelLocation ?? "--")",
            "Backend: \(snapshot.backend)",
            "Voice: \(snapshot.voice)",
            "Reference: \(snapshot.reference)",
            "Language: \(snapshot.language)",
            "Accent: \(snapshot.accent ?? "--")",
            "Request: \(snapshot.request)",
            "Generate: \(snapshot.generation)",
            "Output: \(snapshot.outputFileName.map { "\($0) · \(snapshot.outputDuration.map { String(format: "%.2f s", $0) } ?? "duration unknown")" } ?? "none")",
            "Pipeline:"
        ]
        for stage in stages {
            let duration = stage.durationMilliseconds.map { " · \($0) ms" } ?? ""
            lines.append("\(stage.stage.rawValue): \(stage.state.rawValue)\(duration)")
            if let error = stage.friendlyError { lines.append("  Friendly error: \(Self.redact(error))") }
            if let domain = stage.errorDomain { lines.append("  Error domain: \(domain)") }
            if let code = stage.errorCode { lines.append("  Error code: \(code)") }
            if let raw = stage.underlyingError { lines.append("  Raw error: \(Self.redact(raw))") }
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
}
