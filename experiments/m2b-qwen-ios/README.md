# M2-B Qwen3-TTS iOS runtime spike

This is an isolated feasibility spike. It does not modify the Voice Studio app, its domain model, renderer adapter, or M1 UI. Nothing here is integrated into the product.

## Pinned sources

| Component | Immutable revision | License | Role |
|---|---|---|---|
| Official Qwen3-TTS code reference | `022e286b98fbec7e1e916cb940cdf532cd9f488e` | Apache-2.0 | Official API/conditioning reference; not a device runtime dependency |
| Official Qwen3-TTS 0.6B Base HF snapshot | `dab70521e0956e3db91fb887d36c9a07d21ebc0b` | Apache-2.0 | Weights, tokenizer assets and conversion input |
| `predict-woo/qwen3-tts.cpp` | `b3ba14077cf1b3e11b86e5f84aa9184605c89b28` | MIT | C++ inference runtime and conversion scripts |
| `ggml-org/ggml` submodule | `3af5f5760e19a96427f5f7a93b79cbdf3d4b265b` | MIT | Tensor/backend runtime, including Metal backend |
| Conversion environment | `model/requirements-conversion.txt` | Package-specific | Python conversion/download tools only; not in the iOS inference binary |

The HF `model.safetensors` SHA-256 is `180b3b10eb1c9f1b4db7806d5475bae3071c0243c299d49926bab1da3b6946f6`; `speech_tokenizer/model.safetensors` SHA-256 is `836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258`. The checked-in scripts verify both before conversion. Model assets and generated audio are ignored by Git.

## Run on a Mac

1. Install Xcode with iOS SDK, CMake, Python 3.12, and Git.
2. From this directory run `python3 scripts/prepare_source.py`.
3. Create an isolated Python environment and install `model/requirements-conversion.txt`; set `GGUF_PYTHONPATH` to `upstream/ggml/gguf-py` if needed.
4. Run `python3 scripts/prepare_model.py --python <venv-python>` to fetch the immutable HF snapshot and create F16 GGUF files.
5. Follow `docs/build-macos-xcode.md` to cross-build static libraries for `iphoneos/arm64` and open the Xcode spike project.
6. Install on an iPhone and follow `docs/true-device-checklist.md`.

No result is currently claimed for Windows desktop inference, iOS ARM64 compilation, simulator, or iPhone execution. This checkout has no local CMake/Clang/Xcode/iPhone and outbound GitHub/Hugging Face access is unavailable, so the model preparation/build scripts have not been run here.

Preparation packages are exact-version pinned in model/requirements-conversion.txt and the inference sources are pinned above. The installed spike has no network client: download and conversion happen on a Mac before the local Files folder is copied to the iPhone.

## Known pipeline limitation

The pinned C++ runtime performs reference audio → ECAPA-TDNN speaker embedding → new-text tokenizer → Qwen talker/code predictor → WavTokenizer decoder → 24 kHz mono PCM. Its API has no reference transcript argument. The transcript field in the spike UI is explicitly marked as diagnostic-only and is not sent to the runtime. Therefore this is an x-vector reference-conditioned cloning path, not the official reference-audio-plus-reference-text ICL path. See the research report and compatibility matrix before interpreting device audio.

## Gate B1 iPhoneOS ARM64 CI build

The independent `Qwen iOS Spike Build` workflow runs on GitHub's Apple Silicon `macos-15` runner. It builds the pinned GGML and Qwen runtime sources with the iPhoneOS toolchain, links the static runtime into this spike's Xcode app for `generic/platform=iOS`, verifies arm64 architecture and the final Mach-O `IOS` platform, and uploads `QwenIOSSpike-build`. No model weights or reference audio are required or included. The workflow verifies compilation and linking only; it does not run inference or claim device execution.
