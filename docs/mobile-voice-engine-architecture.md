# Mobile Voice Engine Architecture

## Product boundary

The app owns model-neutral `VoiceAsset`, `VoiceRequest`, and `AudioAsset` data. Rendering providers consume a request and produce a temporary PCM/audio file; the shared audio lifecycle validates and caches the result. Only an explicit save promotes generated audio to durable storage. Voice reference audio remains canonical user data.

```text
Voice selection
    ├─ System voice ── AVSpeechSynthesizer ─┐
    ├─ Saved voice ── selected local clone ─┤
    ├─ Saved voice ── System speech → OpenVoice VC ─┼─> shared DSP ─> AudioAsset
    └─ Local fixed voice ── local generator ┘
```

## Providers and deterministic routing

- **System provider:** `AVSpeechSynthesisVoice` catalog and `AVSpeechSynthesizer.write` generate PCM. Explicit identifiers select the chosen device voice. Personal Voices remain Apple-managed system voices, shown only when the OS enumerates them after its authorization flow.
- **Local generator provider:** Kitten remains a fixed English voice. Qwen remains available for saved-voice cloning as the quality baseline and advanced/experimental route. Qwen's measured iPhone footprint and latency make it unsuitable as the architecture default; no Qwen behavior or pack format is changed in this stage.
- **Voice converter provider:** OpenVoice V2 is an isolated, optional Core ML spike candidate behind a small `VoiceConverterProvider` seam. It consumes generated source speech plus a VoiceAsset reference and must never own or delete that reference. Its model pack stays outside the IPA. The experimental route can be explicitly selected after pack validation and voice embedding preparation; it is not the default route. Quality/performance are not yet validated on a physical device.
- **DSP stage:** AVAudioEngine offline rendering applies pitch/rate and bounded EQ controls after a provider emits audio. DSP does not claim emotion or identity conversion.

Routing is deterministic: system selection uses System; Tiny Local uses its fixed generator; a prepared Saved Voice uses Qwen unless the user explicitly selects System Voice Conversion, in which case Apple system speech feeds OpenVoice VC. The system path never calls the Qwen voice-prepare method. Expression values remain explicitly unsupported until a provider implements them.

## Capability contract

Each provider advertises `supported`, `approximate`, or `unsupported` for generation, cloning, language/accent, speed/pitch, shaping, and expression. The UI exposes only supported controls. Requests outside the bounded DSP parameter ranges fail validation; they are not silently clamped.

Current shared DSP controls are pitch (±1200 cents), rate (0.5×–2×), brightness, clarity, and softness (each normalized −1...1). Brightness/softness use a restrained high shelf; clarity uses a restrained presence band. Their audible quality still requires listening checks on physical devices and representative voices.

## Durable assets and disposable runtime data

- `VoiceAsset` and its canonical reference audio remain durable across provider changes.
- `AudioAsset` stores generated audio and model-neutral source metadata.
- Speaker embeddings and compiled Core ML models are disposable/rebuildable caches, keyed by reference identity and pack revision. They are never the sole copy of a user's voice.
- Optional model packs are installed under app support storage, validated against a manifest and hashes, and deleted independently of voice/audio assets. Large packs are not bundled in the IPA.

## OpenVoice evidence gate

The candidate is the community Core ML conversion of MyShell OpenVoice V2. The pinned upstream source revision is `3a72f7931fce14857c34a15b2d83ffbcaa755e16`; the pinned Core ML package revision is `b0f10347769c88bb6df26e268d4b84bc7237fdeb`. The source and conversion are MIT licensed. The downloaded package payload is 66,024,655 bytes (about 63 MiB): encoder 1,653,738 bytes and converter 64,370,917 bytes. The converter model card advertises iOS 17 and roughly 500 MB peak RAM; the downloaded model tree is 66.2 MB, so its 58 MB figure is not used as the measured payload. These source figures are not iPhone measurements. Runtime compile/load time, RAM, RTF, Chinese/English quality, and the four gender-pair combinations must be verified in the isolated spike before enabling it. Its ~10-second reference guidance means the requested 3–5 second test must be measured rather than assumed.

The optional pack store verifies both immutable revisions, package inventory, byte sizes and SHA-256 values. Pack deletion also clears only the OpenVoice embedding cache; it does not access the voice library or canonical reference audio. The UI exposes install, validate and remove for this pack. The converter card recommends an approximately 10-second reference, following the package guidance; a shorter reference remains unverified.

## Scope decisions

Qwen is preserved as the existing quality baseline because its Chinese cloning behavior has passed the project's physical-device evaluation. OpenVoice remains decoupled because its conversion model and encoder are optional and must not increase the installed app's footprint. MOSS remains a later candidate only if the measured OpenVoice result fails the product's size/quality gate.
