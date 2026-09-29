import XCTest
@testable import VoiceStudioCore

final class SpeechCapabilityTests: XCTestCase {
    func testCapabilityProfileRoundTripsStatesLanguagesAndAccents() throws {
        let profile = CapabilityProfile(
            support: [.speechGeneration: .supported, .voiceCloning: .unsupported,
                      .pitch: .approximate],
            shaping: [.bright: .unsupported],
            expressions: [.gentle: .unsupported],
            languages: ["en-US", "zh-CN"],
            accentsByLanguage: ["en": ["en-US", "en-GB"]])

        let restored = try JSONDecoder().decode(CapabilityProfile.self,
                                                from: JSONEncoder().encode(profile))

        XCTAssertEqual(restored, profile)
        XCTAssertEqual(restored.status(for: .speechGeneration), .supported)
        XCTAssertEqual(restored.status(for: .pitch), .approximate)
        XCTAssertEqual(restored.status(for: .voiceCloning), .unsupported)
        XCTAssertTrue(restored.supports(language: "zh"))
        XCTAssertTrue(restored.supports(language: "en-GB"))
        XCTAssertFalse(restored.supports(language: "ja"))
        XCTAssertEqual(restored.accents(for: "en-GB"), ["en-US", "en-GB"])
    }

    func testProviderSelectionIsDeterministicAndHonorsVoiceIntent() {
        let system = CapabilityProfile(support: [.speechGeneration: .supported], languages: ["en", "zh"])
        let local = CapabilityProfile(support: [.speechGeneration: .supported,
                                                .voiceCloning: .supported], languages: ["en", "zh"])
        let tiny = CapabilityProfile(support: [.speechGeneration: .supported,
                                              .voiceCloning: .unsupported], languages: ["en"])
        let converter = CapabilityProfile(support: [.voiceConversion: .supported], languages: ["en", "zh"])

        XCTAssertEqual(SpeechProviderSelection.select(voice: .systemDefault, language: "zh-CN",
                                                       system: system, local: local, localIsReady: true), .system)
        XCTAssertEqual(SpeechProviderSelection.select(voice: .saved(UUID()), language: "en-US",
                                                       system: system, local: local, localIsReady: true), .local)
        XCTAssertNil(SpeechProviderSelection.select(voice: .saved(UUID()), language: "en",
                                                    system: system, local: local, localIsReady: false))
        XCTAssertNil(SpeechProviderSelection.select(voice: .systemDefault, language: "ja",
                                                    system: system, local: local, localIsReady: true))
        XCTAssertEqual(SpeechProviderSelection.select(voice: .tinyLocal, language: "en-US",
                                                       system: system, local: local, localIsReady: true,
                                                       tinyLocal: tiny), .tinyLocal)
        XCTAssertNil(SpeechProviderSelection.select(voice: .tinyLocal, language: "zh",
                                                    system: system, local: local, localIsReady: true,
                                                    tinyLocal: tiny))
        XCTAssertEqual(SpeechProviderSelection.select(
            voice: .saved(UUID()), language: "zh-CN", system: system, local: local,
            localIsReady: false, voiceConverter: converter, voiceConverterIsReady: true,
            useVoiceConverter: true), .voiceConverter)
        XCTAssertNil(SpeechProviderSelection.select(
            voice: .saved(UUID()), language: "zh-CN", system: system, local: local,
            localIsReady: false, voiceConverter: converter, voiceConverterIsReady: false,
            useVoiceConverter: true))
        XCTAssertNil(SpeechProviderSelection.select(
            voice: .saved(UUID()), language: "ja", system: system, local: local,
            localIsReady: false, voiceConverter: converter, voiceConverterIsReady: true,
            useVoiceConverter: true))
    }

    func testVoiceRequestCarriesOnlyCanonicalUserIntent() throws {
        let request = VoiceRequest(text: "Hello", voice: .systemDefault, language: "en-US",
                                   accent: "en-GB", shaping: VoiceShaping(values: [.bright: 0.4]),
                                   expression: .gentle, speed: 1.15, pitch: 100, renderMode: .generate)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])

        XCTAssertEqual(Set(json.keys), Set(["text", "voice", "language", "accent", "shaping",
                                            "expression", "speed", "pitch", "renderMode"]))
        XCTAssertNil(json["provider"])
        XCTAssertNil(json["model"])
        XCTAssertNil(json["temperature"])
        XCTAssertNil(json["seed"])
    }

    func testVoiceAssetSchemaDoesNotDependOnProvider() throws {
        let voice = VoiceAsset(name: "Independent", sourceType: .record,
                               referenceAudio: AudioAsset(fileName: "reference.wav", duration: 1,
                                                          persistenceState: .persistent))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(voice)) as? [String: Any])
        XCTAssertNil(json["provider"])
        XCTAssertNil(json["renderer"])
        XCTAssertEqual(try JSONDecoder().decode(VoiceAsset.self, from: JSONEncoder().encode(voice)), voice)
    }

    func testCapabilityVisibilityOnlyExposesSupportedShapingAndExpressions() {
        let profile = CapabilityProfile(
            shaping: [.brightness: .supported, .clarity: .approximate, .softness: .unsupported],
            expressions: [.gentle: .supported, .calm: .unsupported])
        XCTAssertEqual(VoiceCapabilityVisibility.visibleShaping(in: profile), [.brightness, .clarity])
        XCTAssertEqual(VoiceCapabilityVisibility.visibleExpressions(in: profile), [.gentle])
    }
}
