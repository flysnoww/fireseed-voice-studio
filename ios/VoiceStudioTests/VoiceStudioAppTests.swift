import XCTest
import VoiceStudioCore

final class VoiceStudioAppTests: XCTestCase {
    func testRendererIsExplicitlyUnavailableInM1() async {
        let renderer = UnavailableRenderer()
        XCTAssertEqual(renderer.capabilities.support(for: .voiceClone), .unsupported)
        let request = VoiceRequest(text: "Hello", voiceID: UUID(), renderMode: .preview)
        let result = await renderer.synthesize(request)
        XCTAssertEqual(result, .unsupported(.voiceClone))
    }
}
