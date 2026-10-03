# M2-C2.2 stability audit (Build 5 candidate)

## Evidence and limits
Build 4 user reports frequent random device exits. No .ips, jetsam report, or matching crash stack was supplied. The defects below are established from code paths, not a proven explanation of those particular exits. MetricKit delivery and sustained iPhone behavior require physical-device validation. Simulator stress is not an iPhone memory-pressure or audio-quality certification.

## Audited paths and changes
- OpenVoice STFT: input shorter than the 256-sample hop could produce a frame whose 1024-sample slice exceeded the padded buffer (Swift negative integer division truncates toward zero). Reject short/nonfinite PCM before indexing; bounded 30-second, stereo-or-mono input before allocation.
- Qwen actor reentrancy: prepare retained a native pointer across awaits while unload could destroy it. An actor-owned in-use gate now defers unload until the owner returns. Native generation remains synchronous and cannot be forcibly interrupted; results are discarded after cancellation. Pinned weights/runtime unchanged.
- All published model mutations remain MainActor. One rendering task and a generation UUID prevent old results committing after A/B/A voice switches, profile edits, source replacement, memory warnings, or background entry. Busy state remains held until work unwinds.
- OpenVoice load/prepare/convert serialized per converter; model pack install/delete/validate serialized against rendering/preparation. Components remain local to their stage; no permanent encoder retention. Reference PCM allocation is bounded; DSP runs off MainActor and checks cancellation each render iteration.
- Native system synthesis/probes share one MainActor queue. A lock-protected PCM writer resumes once; timeout task cancelled on completion. Voice-catalog revision and pending IDs protect notification/probe overlap.
- Player/recorder delegate callbacks hop to MainActor and check instance identity before mutating current state. Background invalidates pending microphone permission results and stops active recording safely.
- Playback, share, conversion, and reference preparation own independent audio leases. Cache eviction/delete can remove the canonical cache entry without invalidating an in-flight reader. Share completion holds its lease independently of card lifetime. Work output removed with defer after success, failure, or stale result. Durable saved references are not evicted.
- One view-owned, bounded FloatingCardStack uses stable voice/audio IDs; deleted assets prune affected routes. Back pops; X dismisses all. Only foremost card handles touches/accessibility. Reduce Motion uses fades. System file/photo/share controllers remain platform presentations; feature navigation is no longer nested sheets.
- Photos existing request gate/cancellation retained; file-picker cancel does not become an import failure. Imports remain synchronous managed copies, so their publication cannot overlap on MainActor.
- OSLog operation names and local MetricKit crash summaries added. Local interrupted-operation breadcrumbs explicitly say crash *or interruption*, not a crash diagnosis. No user text/audio in breadcrumbs and no diagnostic networking.

## Imitation contract
SOURCE = recorded/imported/history performance snapshot. TARGET = current saved Voice canonical reference, independently leased. Existing OpenVoice conversion then persisted speed/pitch DSP. No ASR, transcript, or TTS in this path. Thin PerformanceTransferProvider declares same-content supported, new-text unsupported; nonempty optional text is disabled and rejected before conversion. No model download or cloud implementation added.

AudioAsset has backward-compatible generationKind and referencePerformanceID; saves/rename preserve them. Imitation uses the same two-entry generated cache and explicit Save/History/share lifecycle. Local disposable metadata contains no tensors. No performance preset library.

## Verification plan / pending acceptance
Node tests and local IPA-metadata Python regression; macOS Core/App/UI tests and simulator build. App tests cover short PCM, leases, A/B/A invalidation, delayed stale generation, card-stack twenty-cycle/deletion recovery, performance SOURCE/TARGET separation and unsupported new text. UI regression includes real system TTS, real pinned CoreML conversion, ten real same-content conversions, and twenty detail/option cycles. The converter unit stub proves routing, not model quality; real CoreML runs are separately identified in UI tests.

Required release gates: ios-ci, ios-test-package, unsigned IPA; existing signed TestFlight 0.1 (5) archive/export/IPA preflight/upload; Apple ingestion VALID. Never equate upload success with ingestion. Final execution results and exact IDs will be reported after those gates finish.

## Device checklist
10–15 minutes switching voices, recording/importing, preview/stop/generation, opening/closing layered cards; ten repeated generations; background during conversion; interruptions; share while navigating; Voice Detail speed/pitch persistence and all actions; same-content imitation content/rhythm/intonation/identity listening. New-text imitation is unavailable. If another exit occurs, export local diagnostics and obtain the matching iOS Analytics .ips/jetsam report before assigning a root cause.

## CI-discovered regression and concrete evidence
Run 37072558767 exported simulator crash 9EC68D6D-9FED-41BA-9B94-472BD15D8422: EXC_BAD_ACCESS on MetricKit's asynchronous removeSubscriber queue (objc_msgSend → NSConcreteHashTable removeItem → MXMetricManager removeSubscriber). The newly added per-model collector deregistered itself during deinit. It now has process lifetime; individual diagnostics models use removable NotificationCenter observers instead. A 100-model release regression covers this ownership boundary. This is a confirmed candidate-build regression, not proof of the user's Build 4 device crash cause.
UI evidence also exposed background cards' controls in accessibility. Each layer now explicitly contains front children or ignores back children before hiding it; tests require exactly one hittable Back control; XCTest can still enumerate noninteractive controls retained in visual back layers. The probe progress area keeps a stable height so arriving voice results do not move the first selection under a tap.
