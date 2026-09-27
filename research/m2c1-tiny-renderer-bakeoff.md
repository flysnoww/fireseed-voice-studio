# M2-C1 Tiny Local Renderer Bake-off

Research checked 2026-09-27. Sizes below use published model/package figures; the CI IPA is the authoritative integrated runtime measurement.

| Candidate | Model and language | Model assets | iOS/runtime evidence | License and commercial notes | Decision |
| --- | --- | ---: | --- | --- | --- |
| Kitten TTS Nano int8 | 15M, English, 8 fixed voices | 23.8 MB ONNX + about 10 KB voices/config; SDK reports about 25 MB | Official Swift SDK supports iOS 16+, exports 24 kHz WAV, and uses ONNX Runtime; CPU path | Swift SDK Apache-2.0; exact Nano 0.2 model card Apache-2.0. Built-in phonemizer separately downloads GPL-3.0 data at first use. | Selected for this integration candidate: smallest direct Swift path. License boundary and developer-preview maturity are documented risks. |
| Piper VITS / sherpa-onnx | English voice, `en_US-lessac-medium` | 63.2 MB ONNX plus small config/token files | sherpa-onnx documents offline iOS TTS and Swift examples; CPU-capable | sherpa-onnx is Apache-2.0; voice/model terms vary per voice and must be checked individually (the current Lessac medium metadata is not treated as a blanket Piper license). Runtime likely comparable to full ONNX Runtime, so total is at least model plus runtime. | Not selected: larger model and adds a separate C/C++ iOS runtime integration. |
| Supertonic 3 | 31 languages, including English and Chinese | About 400 MB model download | Upstream documents on-device ONNX and an iOS example; archive is no longer maintained | Code MIT; model OpenRAIL-M with additional use restrictions. | Excluded: exceeds the 300 MB ceiling and archived model/runtime line. |

## Selected integration

- Product selection label: **Local Voice**. Internal renderer: `KittenTTS-Nano-int8`.
- Provider ID is separate from Apple System and Qwen Advanced Local. It accepts only `VoiceSelection.tinyLocal`, English text, and generate requests; it does not consume Saved Voice reference audio and advertises cloning as unsupported.
- Output is WAV from the renderer and then enters the existing generated-audio, DSP, preview, and Save Audio path.
- The model is not committed or embedded in the IPA. The upstream SDK fetches the model and phonemizer assets on first explicit Generate and caches them under `Application Support/RendererPacks/TinyLocal`; subsequent generation is on-device/offline. Settings reports cache readiness and can remove this Tiny pack without touching Saved Voice or generated audio assets.
- Model assets are roughly 23.8 MB. ONNX Runtime adds roughly 22–48 MB in published iOS package figures (a later reported full framework was 64.6 MB); the total will be measured from this commit's IPA and compared with the preceding package. This is materially larger than the weight alone and remains a candidate pending real iPhone memory/speed evaluation.
- The upstream Kitten SDK calls itself an early/developer-preview project. The successful CI build proves package integration, not iPhone runtime performance or voice quality.

## Fixed source references

- [KittenTTS Swift SDK](https://github.com/KittenML/KittenTTS-swift) and [SDK README](https://github.com/KittenML/KittenTTS-swift#readme); dependency pinned in Xcode to 0.1.0.
- [Kitten Nano 0.2 model card and files](https://huggingface.co/KittenML/kitten-tts-nano-0.2/tree/main), Apache-2.0, ONNX file listed at 23.8 MB.
- [ONNX Runtime Swift Package Manager](https://github.com/microsoft/onnxruntime-swift-package-manager), required transitively by Kitten SDK starting from 1.20.0.
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) TTS documentation covers Kokoro and Piper; [Lessac medium model metadata](https://github.com/rhasspy/piper/blob/master/src/python_run/piper/voices.json) lists 63,201,294 model bytes.
- [Supertonic 3 archived source](https://github.com/supertone-oss-archive/supertonic) documents its archived state, multilingual scope, MIT code license, and OpenRAIL-M model license; [official Python model card](https://github.com/supertone-oss-archive/supertonic-py) reports approximately 400 MB.

## Verification boundary

CI can verify compilation, core provider selection/capability behavior, existing XCTest regressions, and IPA packaging without downloading weights. A device must still verify first-run asset download, airplane-mode reuse, generation latency/RTF, memory footprint, playback, and perceived voice quality. No iPhone result is inferred from CI.
