import XCTest
@testable import VoiceStudioCore

final class RendererManifestTests: XCTestCase {
    func testCapabilityManifestRoundTripsCanonicalStatesAndLanguageList() throws {
        let manifest = RendererCapabilityManifest(
            support: [.voiceClone: .supported, .timbreControl: .unsupported,
                      .instructionControl: .approximate],
            supportedLanguages: ["en", "zh"])

        let restored = try JSONDecoder().decode(RendererCapabilityManifest.self,
                                                from: JSONEncoder().encode(manifest))

        XCTAssertEqual(restored, manifest)
        XCTAssertEqual(restored.status(for: .voiceClone), .supported)
        XCTAssertEqual(restored.status(for: .instructionControl), .approximate)
        XCTAssertEqual(restored.status(for: .timbreControl), .unsupported)
        XCTAssertEqual(restored.status(for: .accentControl), .unsupported)
    }

    func testRendererPackContractRejectsUnsafeOrIncompleteInventory() throws {
        let valid = RendererPackManifest(
            packID: "local.voice.standard", rendererID: "local.voice",
            variant: "standard", version: "1", requiredFiles: [
                RendererPackFile(path: "weights/model.gguf", bytes: 10, sha256: String(repeating: "a", count: 64))
            ], capabilities: RendererCapabilityManifest(support: [.voiceClone: .supported]))
        XCTAssertTrue(valid.isStructurallyValid())

        let unsafe = RendererPackManifest(
            packID: "local.voice.standard", rendererID: "local.voice",
            variant: "standard", version: "1", requiredFiles: [
                RendererPackFile(path: "../model.gguf", bytes: 10, sha256: String(repeating: "a", count: 64))
            ], capabilities: RendererCapabilityManifest(support: [:]))
        XCTAssertFalse(unsafe.isStructurallyValid())
    }
}
