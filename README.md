# Fireseed Voice Studio

An independent, local-first native iOS Voice Generation / Voice Creation app using Swift, SwiftUI, and AVFoundation. The M0 Node.js/browser harness remains a domain and cache prototype and quick test tool; it is not the product UI or an iOS packaging target.

## M0 harness

Requires Node.js 20 or newer.

~~~sh
node --test
node server.js
~~~

Open http://127.0.0.1:4173. The harness uses Node.js built-ins and browser modules with no external packages. Its mock renderer returns data-only placeholders; it does not record, play, or synthesize audio.

## Native iOS M1

- Xcode project: ios/VoiceStudio.xcodeproj (bundle ID com.fireseed.voicestudio, iOS 17.0+).
- Swift domain, file store, and cache: ios/VoiceStudioCore.
- SwiftUI app and AVFoundation audio services: ios/VoiceStudioApp.
- macOS CI and internal IPA packaging: .github/workflows/ios-ci.yml and .github/workflows/ios-test-package.yml.

Recording, managed audio import, playback, and saving a voice reference are implemented natively. Preview and Generate remain disabled because no renderer is integrated. The package produces an unsigned IPA for Sideloadly; no Apple signing credentials are stored in GitHub.

The Windows workspace cannot run Xcode. Treat GitHub Actions macOS results as the authoritative Apple build and test results.