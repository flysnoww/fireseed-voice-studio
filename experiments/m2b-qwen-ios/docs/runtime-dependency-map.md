# Runtime dependency map and clone completeness

## Executed path in pinned `qwen3-tts.cpp`

```text
Reference WAV
  → RIFF/WAVE reader (`qwen3_tts.cpp::load_audio_file`)
  → PCM16 / PCM32 / IEEE float decode, channel average to mono
  → linear resample to 24 kHz when needed
  → ECAPA-TDNN speaker encoder (`AudioTokenizerEncoder::encode`)
  → 1024-float speaker embedding
  → new-text BPE tokenizer (`TextTokenizer::encode_for_tts`)
  → Qwen talker (28 layers) + autoregressive 5-layer code predictor
  → 16 codebooks / 12 Hz speech-code frames
  → WavTokenizer decoder (`AudioTokenizerDecoder::decode`)
  → 24 kHz mono float PCM
```

## Layer-by-layer platform classification

| Layer | Source / dependency | Classification | Reason and risk |
|---|---|---|---|
| File access and WAV parse | `src/qwen3_tts.cpp::load_audio_file`, stdio and RIFF` | PURE C/C++, IOS LIKELY | iOS has stdio; decoder accepts limited WAV encodings only. |
| Mono / 24 kHz preprocessing | `src/qwen3_tts.cpp` | PURE C/C++, IOS LIKELY | C++ linear resampler; compare with known audio vectors on device. |
| Speaker encoder and embedding | `src/audio_tokenizer_encoder.cpp` | PURE C/C++, IOS LIKELY | GGML CPU ops; memory and ARM kernels unbuilt here. |
| Reference transcript prompt | No implementation in pinned C++ API | BLOCKER | This missing component prevents claiming official reference-audio-plus-transcript ICL cloning. |
| Text BPE | `src/text_tokenizer.cpp` | PURE C/C++, IOS LIKELY | GGUF vocab/merges; test Chinese and English vectors. |
| Talker and code predictor | `src/tts_transformer.cpp` | PURE C/C++, IOS LIKELY | GGML path plausible; optional ObjC++ CoreML branch is MACOS ONLY in upstream docs. |
| Audio codec decoder / vocoder | `src/audio_tokenizer_decoder.cpp` | PURE C/C++, IOS LIKELY | GGML graph and weights; must compile and measure on iPhone. |
| GGUF tensor load / filesystem | `src/gguf_loader.cpp`, GGML` | PURE C/C++, IOS LIKELY with changes | Static path and iOS archive detection need the prepared local patch; file-provider scope matters. |
| Metal | `ggml/src/ggml-metal` | APPLE FRAMEWORK, LIKELY PORTABLE | Metal/MetalKit frameworks and embedded MSL path; no pinned iPhone compile/run evidence. |
| CoreML bridge/export | `src/coreml_code_predictor.mm`, converter` | APPLE FRAMEWORK, MACOS ONLY | Existing Qwen build/export describes the bridge as macOS-only; disabled for baseline. |
| Apple process footprint | `src/qwen3_tts.cpp` | APPLE FRAMEWORK, UNKNOWN | `__APPLE__` path uses Mach TASK_VM_INFO without explicit iOS guards. |
| Objective-C runtime | `src/qwen3tts_c_api.cpp` | APPLE FRAMEWORK, IOS LIKELY | Uses objc_msgSend/NSAutoreleasePool; iOS runtime availability expected, build/thread lifecycle unverified. |
| POSIX/threading | C stdio, `Threads::Threads` and GGML worker APIs | IOS LIKELY | iOS supplies pthread/C++ threading, but actual static link and scheduler behavior remain unbuilt. |
| SIMD / Accelerate | GGML architecture code and optional Apple Accelerate | IOS LIKELY / UNKNOWN | ARM64 CPU path exists; spike disables Accelerate/BLAS to isolate baseline. Compile flags must not use host -march=native. |
| Shell/process calls | converter subprocess before install; no inference-shell path observed | NOT IN DEVICE RUNTIME | No fork/exec/system or Python launch in inference sources reviewed. |
| Python | HF download and pinned conversion scripts only | NOT IN DEVICE RUNTIME | Python/PyTorch stay off-device. |
| Spike audio UI | SwiftUI, UIKit, AVFoundation | APPLE FRAMEWORK, IOS LIKELY | Standard iOS APIs; file-provider scope and recorder behavior need device checks. |

No direct mmap or dlopen call was found in the reviewed Qwen inference path. Static build sets GGML_BACKEND_DL=OFF. This is source inspection, not a binary dependency scan.

## Source-level entry points

| Stage | Pinned source entry point | Result / finding |
|---|---|---|
| Model loading | `src/qwen3_tts.cpp::Qwen3TTS::load_models` | Opens the transformer/tokenizer GGUF and decoder GGUF; Q8_0 main file is preferred if present, else F16. Low-memory mode can unload/reload components. |
| Reference file | `src/qwen3_tts.cpp::Qwen3TTS::synthesize_with_voice(text, reference_audio, params)` | Calls the WAV-only `load_audio_file`, then linearly resamples to 24 kHz and forwards mono floats. |
| Reference raw samples | `src/qwen3_tts.cpp::Qwen3TTS::synthesize_with_voice(text, float*, count, params)` | Loads the speaker encoder lazily, extracts x-vector, and invokes `synthesize_internal`. The API documents 24 kHz mono float32 in [-1,1]. |
| Speaker prompt | `src/audio_tokenizer_encoder.cpp::AudioTokenizerEncoder::encode` and `src/qwen3_tts.cpp::synthesize_internal` | Builds speaker embedding; that vector is placed in the talker prefill. This is speaker-vector conditioning. |
| New-text tokenizer | `src/text_tokenizer.cpp::TextTokenizer::encode_for_tts` | Reads vocab/merges from GGUF and creates the text-side tokens. |
| Acoustic generation | `src/tts_transformer.cpp::TTSTransformer::generate` | Builds prefill, autoregressively generates codebook-0, then predicts codebooks 1–15. KV caches use F16 tensors. |
| Code predictor | `TTSTransformer::predict_codes_autoregressive` or its CoreML variant | GGML path is the baseline. Optional CoreML code-predictor branch is separate. |
| Codec/vocoder | `src/audio_tokenizer_decoder.cpp::AudioTokenizerDecoder::decode` | Maps generated code frames to waveform. Result is 24 kHz mono float PCM. |
| C ABI | `src/qwen3tts_c_api.h` / `.cpp` | Exposes create/destroy, extract embedding from WAV, synthesize with embedding, raw-WAV cloning, audio release, and errors. It does not expose reference text. |

## Is the complete official cloning path present?

**No. Exact missing layer:** the runtime does not accept or use `ref_text` (reference transcript), does not encode the reference transcript into the TTS prompt, and does not encode the reference audio into the official ICL speech-token prompt. Its cloning call is `new_text + reference_audio → speaker x-vector → generated speech`.

The official Python model-card example passes both `ref_audio` and `ref_text` to `generate_voice_clone`. The pinned C++ implementation's `synthesize_with_voice` overloads take either a WAV path or PCM samples, and the C API has no transcript field. Community issue #18 independently reports that the reference transcript is not implemented. Thus the C++ chain is a real reference-speaker-conditioned clone path; it is not the complete official audio-plus-transcript ICL path, and it may lose source pacing/pronunciation cues. The diagnostic transcript textbox must never be represented as model conditioning.

## Audio decoder boundary

The C++ file loader recognizes RIFF/WAVE only, with PCM16, PCM32, or IEEE float32 data. It averages channels to mono and resamples with a simple linear interpolator. It does not decode M4A/MP3/etc. The iOS spike therefore records or decodes with AVFoundation and supplies a WAV file to the pinned C API. This is a spike adapter responsibility, not a new app audio feature.

## Thin iOS boundary

The spike Swift wrapper is deliberately smaller than a product renderer:

```text
QwenRuntime.loadModel(modelDirectory, backendMode)
QwenRuntime.prepareReference(referenceWavURL, transcriptForRecordOnly)
QwenRuntime.synthesize(newText) -> 24 kHz mono WAV URL + timing
QwenRuntime.unload()
```

`prepareReference` calls `qwen3_tts_extract_embedding_file`, stores the returned embedding only in the in-memory spike session, and records that the transcript was not forwarded. `synthesize` calls `qwen3_tts_synthesize_with_embedding`. No formal `RendererAdapter`, domain model, model downloader, or Voice Studio integration is added.
