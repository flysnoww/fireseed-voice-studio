# M2-B Qwen3-TTS iOS runtime research

## State and scope

This is an isolated feasibility spike. No formal Voice Studio app, audio model, renderer adapter, or product flow has been changed. M2-B is **AWAITING IOS DEVICE VALIDATION**. Static inspection does not establish that the CMake patch, Xcode project, binary, inference, Metal, or memory behavior works on iPhone.

## Immutable source pins

| Source | Revision | License / role |
|---|---|---|
| Official [Qwen3-TTS code](https://github.com/QwenLM/Qwen3-TTS/commit/022e286b98fbec7e1e916cb940cdf532cd9f488e) | `022e286b98fbec7e1e916cb940cdf532cd9f488e` | Apache-2.0 research reference and model's official API semantics |
| Official [0.6B Base HF model](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base/tree/dab70521e0956e3db91fb887d36c9a07d21ebc0b) | `dab70521e0956e3db91fb887d36c9a07d21ebc0b` | Apache-2.0 model/tokenizer assets |
| [C++ runtime](https://github.com/predict-woo/qwen3-tts.cpp/commit/b3ba14077cf1b3e11b86e5f84aa9184605c89b28) | `b3ba14077cf1b3e11b86e5f84aa9184605c89b28` | MIT inference/conversion code |
| [GGML submodule](https://github.com/ggml-org/ggml/tree/3af5f5760e19a96427f5f7a93b79cbdf3d4b265b) | `3af5f5760e19a96427f5f7a93b79cbdf3d4b265b` | MIT tensor and backend runtime |

The two large original model files are checked by SHA-256 in `experiments/m2b-qwen-ios/scripts/prepare_model.py`: main weights `180b3b10eb1c9f1b4db7806d5475bae3071c0243c299d49926bab1da3b6946f6`; speech tokenizer `836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258`. Official model files total about 2.52 GB before converted files and runtime memory. The repository contains no weight files.

## Clone path audit

The official model API example uses `ref_audio` **and** `ref_text`. In the pinned C++ runtime, `synthesize_with_voice` accepts only WAV or raw PCM. It decodes the reference, downmixes to mono, resamples to 24 kHz, extracts an ECAPA-TDNN speaker embedding, then conditions the new-text generation on that vector. The path continues through Qwen's talker, its code predictor and the WavTokenizer decoder to 24 kHz mono float audio. There is no reference transcript argument or transcript-token prompt in the public C ABI. Therefore this spike tests a real x-vector-conditioned voice cloning path, but not the official reference-audio-plus-reference-text ICL path. The transcript field is labeled diagnostic-only and is not sent to the model.

The runtime's C++ WAV reader handles RIFF PCM16/PCM32 and IEEE float32, but not MP3/M4A or other general formats. The spike only offers a WAV importer and records WAV locally with AVFoundation; broad audio import belongs outside this experiment.

## iOS feasibility and unresolved compatibility

The C++ inference and GGML CPU code appear portable, but upstream has no iOS target or demonstrated iOS artifact. The qwen build uses `-march=native`, expects a Metal dylib, and has an upstream CoreML route documented as macOS-only. The isolated patch removes native-host tuning for iOS cross builds, recognizes a static Metal archive, builds a static C API target and reports the GGML device name. The CMake toolchain targets physical `iphoneos/arm64`; CoreML is disabled for the baseline. GGML Metal embedded-source mode avoids its alternative `xcrun -sdk macosx metal` compile path.

The static matrix is in `experiments/m2b-qwen-ios/docs/IOS_COMPATIBILITY_MATRIX.md`. Metal/MetalKit exist on iOS, but their use in this pinned build remains unverified. The upstream `__APPLE__` process-footprint branch uses `mach/mach.h` and `TASK_VM_INFO` without separate iOS guards: classify this as unknown until an Xcode build and device measurement. Qwen's C ABI also uses Objective-C autorelease pools; background-thread runtime behavior is unverified.

## Memory estimate, not measurement

Weights alone: about 2.52 GB in source form. F16 GGUF outputs add roughly another model-sized storage footprint, plus temporary conversion copies. The conversion host should have at least 12 GB free as a practical estimate; this is not a proven minimum.

At 4096 cached tokens, the talker's 28 layers × 8 KV heads × 128 dimensions × key/value × 2-byte F16 is approximately 469 MB before graph, activations, weights, decoder and allocator overhead. The 5-layer code predictor's short-lived KV cache is small by comparison (approximately 0.3 MiB for 16 frames under the same representation). These are tensor-capacity estimates, not measured iPhone peaks. Device memory and thermal viability must be measured on the target iPhone.

## Prepared experiment contents

`experiments/m2b-qwen-ios/` includes exact source pins, two large-weight integrity checks, conversion dependency version pins, a repeatable model preparation script, static-source patch, iOS compatibility matrix, dependency map, Xcode/CMake build instructions, SwiftUI/AVFoundation experiment app, and device checklist. Generated weights, audio, and local Python environments are ignored. No model download or conversion has run in this Windows environment.

The UI keeps model files local, has WAV selection/recording, transcript diagnostic field, new text, Auto/CPU modes, load/prepare/generate/unload, audio playback, backend/timing/RTF/physical-footprint/memory-warning display. This is an experiment app in its own Xcode project and is not linked to the product app.

## Metal-specific audit

Pinned GGML links Metal, MetalKit, and Foundation and compiles Objective-C sources. Apple publishes Metal support for iOS. With GGML_METAL_EMBED_LIBRARY enabled, its CMake assembles MSL source into an embedded data section for the runtime library-creation path. If embedding is disabled, the inspected build path invokes xcrun with the macosx SDK for metal/metallib, which is MACOS ONLY. Qwen's existing integration detects only a Metal dylib; the local patch recognizes the static archive. The code path is **LIKELY PORTABLE** after that build change, but buffer allocation, runtime shader compile, kernel support, peak memory, and correctness have no iPhone evidence. CPU selection targets arm64 with GGML_NATIVE disabled; no x86 inference dependency was identified in reviewed sources.

## Evidence and remaining gates

Verified here: source/license/API research against pinned repository snapshots; repeatable script and static patch files authored; repository diff whitespace check. Not verified here: preparation/conversion, desktop inference, iOS CMake compile, Xcode build, Swift/C ABI importer compatibility, iPhone install, voice cloning quality, CPU-vs-Metal, memory/thermal behavior, offline run.

The current host is Windows and has no CMake, Clang, Xcode, Swift, GitHub CLI, model cache, or connected iPhone; network access to GitHub/Hugging Face is unavailable. The authoritative next action is to run `experiments/m2b-qwen-ios/docs/build-macos-xcode.md` on the prepared Mac/Xcode host, fix any actual compiler/linker errors minimally, install to a physical iPhone, then record every item in `docs/true-device-checklist.md`. Do not report M2-B as green until that evidence exists.

### Primary references

- [Official Qwen3-TTS 0.6B Base model card](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-0.6B-Base)
- [Pinned official Qwen3-TTS source](https://github.com/QwenLM/Qwen3-TTS/commit/022e286b98fbec7e1e916cb940cdf532cd9f488e)
- [Pinned C++ runtime source](https://github.com/predict-woo/qwen3-tts.cpp/commit/b3ba14077cf1b3e11b86e5f84aa9184605c89b28)
- [Pinned GGML submodule](https://github.com/ggml-org/ggml/tree/3af5f5760e19a96427f5f7a93b79cbdf3d4b265b)
- [Apple Metal documentation](https://developer.apple.com/documentation/metal?changes=_1_5)
- [Apple Metal libraries](https://developer.apple.com/documentation/metal/metal-libraries)
- [Apple Accelerate](https://developer.apple.com/accelerate/)
