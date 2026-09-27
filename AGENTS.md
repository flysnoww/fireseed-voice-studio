# Fireseed Voice Studio — Project Protocol

Fireseed Voice Studio is an independent, local-first tool for creating voices. Its current scope is Voice Generation / Voice Creation only. It does not depend on or know about Language Learning or Dub Together.

## Product principles

- Product first: build a usable product slice before extracting shared layers. Follow `Duplicate → Compare → Generalize → Extract → Verify → Share`. Do not add speculative abstractions.
- Local first: core capabilities should work locally. Cloud rendering may later be an optional provider, never a runtime requirement.
- Stable interface, replaceable model: product concepts and asset formats stay independent of a specific TTS or voice-clone model. UI, persistence, and business logic must not depend on model names or model-only parameters.
- AI may understand or generate; deterministic code validates, persists, caches, and manages file lifetimes.
- Preserve semantic truth. Report architecture problems; do not silently bypass contracts or validation.

## Product boundary

The core concepts are `Voice` (who speaks), `Accent` (which accent), `Attributes` (how they speak), `Text` (what they say), and `AudioAsset` (generated audio).

The intended simple loop is choose or create a voice → enter text → preview → adjust → generate → save or share. Record and import are voice sources. A Mock or BuiltIn renderer may prove the data flow when no real clone renderer is available, but it must label mock output and must never claim unsupported capabilities.

Do not implement Language Learning, pronunciation scoring, Speech Comparator, Dub Together, Scene/Line/Target/Take/Version, community, feed, user accounts, cloud sync, a complex provider registry, Timbre IR, a large planner, model training, Qwen Audio scene generation, or video generation in this project. Do not download or integrate large models without a new explicit task.

## Data and model boundaries

- Keep `VoiceAsset`, `AudioAsset`, and `VoiceRequest` minimal and model-neutral.
- Canonical `VoiceAsset` fields include identity/name/source, reference audio, language hint, default accent/attributes, disposable renderer cache references, and timestamps.
- Canonical `AudioAsset` fields include identity, file path/URL, duration, creation time, source voice ID, text, and persistence state.
- Canonical `VoiceRequest` contains text, voice, language, accent, attributes, and `renderMode` (`preview` or `generate`). Never add temperature, CFG, seed, or other renderer-specific parameters to canonical product data.
- Capabilities must be explicit. Supported behavior may run, approximate behavior must be labeled as approximate, and unsupported behavior must return an unsupported result.
- Keep the renderer adapter thin. Playback may live in a separate audio service.
- Voice is the durable user asset. Reference audio is a migration fallback. Renderer caches are disposable and rebuildable.

## Cache and persistence lifecycle

- Preview cache capacity is 5, evicted FIFO.
- Unsaved generated-audio cache capacity is 2, evicted FIFO.
- Only an explicit Save places audio in persistent storage. Save copies/promotes a cached asset to persistence.
- Cache eviction removes only volatile cache data; it must never delete a saved asset.
- Preview and Generate are distinct modes and must retain their separate policies.

## Engineering workflow

- Audit existing files before changing them. Keep changes scoped and reversible; prefer platform capabilities and existing dependencies before adding dependencies.
- The product target is native iOS, using Swift, SwiftUI, and AVFoundation. Keep future local AI rendering behind a separate `RendererAdapter`.
- Windows is the local development host; use the established GitHub repository → GitHub Actions macOS runner → Xcode build/test → IPA artifact → Sideloadly device-test workflow. Reuse a verified Fireseed workflow when available. Do not switch to Android or wrap the web harness in a WebView.
- Keep the M0 JavaScript/Web harness as a domain/cache prototype and quick test tool only. Do not expand it into the product UI.
- Test every code change with the smallest relevant tests. Do not delete tests or weaken assertions to make tests pass.
- Validate written data and important invariants after changes. Do not hide or bypass an architecture issue to obtain a green result.
- Respect explicit milestone boundaries. Do not continue into later product stages after a milestone says to stop.
- At each milestone, report the actual state, verified behavior, known limitations, and a practical next step. Never describe mock functionality as real model or audio functionality.

## Future shared capabilities

Keep the current implementation local to this product. Extract a shared capability only after the same need appears repeatedly in real products: duplicate, compare, generalize, extract, verify, then share.

## M1 native iOS boundary

- The authorized native audio slice is Record → managed audio file → playback, and Import → managed audio copy → playback, with Save Voice promoting its reference audio to durable storage.
- M1 does not include AI rendering, voice cloning, model downloads, complex UI, or excluded future products. Preview and Generate stay clearly unavailable until a real renderer is authorized and integrated.
- On Windows, do not claim an Apple build passed locally. The GitHub Actions macOS workflow is authoritative. Internal device packages are unsigned IPA artifacts for Sideloadly; do not add Apple signing secrets or certificates.

## CI Closed-Loop Rule — Mandatory

For any task whose acceptance criteria include GitHub Actions, CI, builds,
tests, IPA/APK/package generation, or downloadable artifacts:

1. A successful `git push` is NOT task completion.
2. `queued`, `pending`, or `in_progress` CI is NOT task completion.
3. After push, continue monitoring the required GitHub Actions workflows.
4. If CI fails:
   - read the real CI/build/test logs;
   - identify the root cause;
   - make the minimum necessary fix;
   - run locally available tests;
   - commit;
   - push;
   - monitor CI again.
5. Repeat the loop until all required workflows are successful and every
   required artifact has actually been generated and verified.
6. Do not stop merely because `gh` CLI is unavailable.
   Use the authorized GitHub connector/API when available.
7. Stop before completion only when there is a genuine external blocker that
   requires user action, permission, credentials, hardware interaction, or
   another action that cannot be performed by Codex.
8. When user action such as a manual `git push` is required, ask for that
   action explicitly. After the user completes it, resume the same acceptance
   loop; do not treat the manual step as the end of the task.
9. Report completion only after the original acceptance criteria are actually met.

Canonical loop:

Implement
→ Test
→ Commit
→ Push
→ Monitor CI
→ Read failures
→ Fix
→ Test
→ Commit
→ Push
→ Monitor CI
→ Required CI succeeds
→ Required artifact exists
→ Report completion

Codex 的“任务停止条件”必须来自验收标准，而不是来自它当前完成了什么操作。