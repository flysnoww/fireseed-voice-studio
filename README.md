# Fireseed Voice Studio

An independent, local-first M0 prototype for the Voice Generation / Voice Creation product. The product direction is native iOS with Swift, SwiftUI, and AVFoundation. The current Node.js/browser harness remains a domain and cache prototype and quick test tool; it is not the product UI or an iOS packaging target.

## Run

Requires Node.js 20 or newer.

```sh
npm test
npm start
```

Open `http://127.0.0.1:4173`. There are no external package dependencies. The current workspace environment includes Node.js but not npm, so use `node --test` and `node server.js` directly there.

## M0 status

The domain records, explicit renderer capability responses, FIFO caches, save promotion, and a data-only mock renderer are implemented. The browser shell demonstrates mock voice → text → preview/generate → save data flow. It does not record microphone input, play audio, or generate sound. No native iOS project exists yet. iOS builds and tests will run through the established GitHub Actions macOS workflow, with an IPA artifact for Sideloadly device testing.
