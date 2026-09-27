# Voice Studio capability pipeline

Voice Studio is a local-first voice creation product. Its user flow is Voice → Text → Shaping → Expression → Language/Accent → Generate → Preview → Save/Export. The interface describes user intent and does not expose provider or model implementation details.

## Stable product data

- `VoiceAsset` stores the user's voice identity, metadata, and canonical reference `AudioAsset`. It contains no provider or model identifiers.
- `AudioAsset` is the managed audio result. Explicit save promotes generated audio to persistent storage; temporary provider inputs and caches do not own durable voice assets.
- `VoiceRequest` carries text, `VoiceSelection`, language, accent, shaping values, expression, speed, pitch, and render mode. It contains no sampling or model-specific settings.

## Capability and providers

`CapabilityProfile` is a small, model-neutral statement of supported, approximate, and unsupported controls plus available languages and accents. The UI only activates controls backed by a declared capability. Provider choice is deterministic: system voice requests use the system provider when its profile supports the language; saved-voice requests use the local provider only when it is installed and declares voice cloning and language support. Unsupported requests do not silently fall back to a different voice.

`SpeechProvider` accepts the same `VoiceRequest` and returns a rendered file, an unsupported capability, or a failure. A provider may internally use one or more replaceable components, but this stage has no planner or provider registry. The install seam is separate from speech generation.

## Current iOS components

- Apple System Speech uses `AVSpeechSynthesizer` and available `AVSpeechSynthesisVoice` entries to generate speech buffers for the shared preview and save path.
- `AVAudioUnitTimePitch` provides speed and pitch adjustment after generation.
- The current local provider is the Qwen implementation behind `SpeechProvider`; its model/runtime naming and package validation remain inside that adapter.
- Voice shaping presets and expression controls remain unavailable until a provider reports real supported or approximate behavior.

Android can later implement the same request, result, and capability semantics with its own system APIs. No Android application or adapter is part of this stage.
