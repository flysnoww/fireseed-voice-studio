# Model assets

## Immutable input

- Repository: `Qwen/Qwen3-TTS-12Hz-0.6B-Base`
- Revision: `dab70521e0956e3db91fb887d36c9a07d21ebc0b`
- License: Apache-2.0 (as declared by the official model repository)
- Snapshot size reported by Hugging Face: about 2.52 GB; this contains the talker/speaker assets, tokenizer files, and the speech tokenizer.
- Expected large files:
  - `model.safetensors` — 1.83 GB, SHA-256 `180b3b10eb1c9f1b4db7806d5475bae3071c0243c299d49926bab1da3b6946f6`
  - `speech_tokenizer/model.safetensors` — 682 MB, SHA-256 `836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258`

## Conversion

The pinned upstream converter consumes the official SafeTensors snapshot and creates:

- `model/assets/qwen3-tts-0.6b-f16.gguf`
- `model/assets/qwen3-tts-tokenizer-f16.gguf`

Reproducible command (the script executes these exact upstream steps after validating both source hashes):

```text
python upstream/scripts/setup_pipeline_models.py \
  --models-dir model/assets \
  --skip-download \
  --coreml off
```

No quantization is applied by the prepared baseline; outputs are F16. `convert_tts_to_gguf.py` accepts `q8_0` and `q4_k`; `convert_tokenizer_to_gguf.py` accepts `q8_0`. Quantized variants remain unmeasured for audio quality and device memory. The exact conversion source is pinned to the runtime commit. Python package versions are pinned in `requirements-conversion.txt`; GGUF Python code comes from the pinned `ggml/gguf-py` submodule. This command omits `--force`: upstream would delete the source snapshot and redownload without our exact revision pin.

After conversion, `prepare_model.py` writes an ignored local manifest containing the resolved source SHA, converter source SHA, dependency versions, file sizes, and SHA-256 digests for both generated GGUF files. The artifacts must not be added to Git.

## Memory sizing (estimates unless stated otherwise)

| Variant | Runtime GGUF weight estimate | Notes |
|---|---:|---|
| F16 | ~2.08 GB runtime weights | Upstream desktop report: main GGUF ~1.75 GB and separate decoder ~326 MB; exact generated file sizes unavailable. |
| Q8_0 | ~1.50–1.63 GB estimate | Main GGUF ~1.3 GB in upstream desktop report; tokenizer estimate 0.20–0.33 GB is unmeasured. |
| Q4_K | ~1.23–1.53 GB estimate | Main file rough 0.9–1.2 GB estimate; decoder stays F16 because no Q4 decoder conversion path. No Q4 output validated. |

Additional inference memory, separate from on-disk model size:

- KV cache: F16 by source. For 28 talker layers × 8 KV heads × 128 head width × K+V × 2 bytes × (`prefill length + max audio tokens + 8`), the default 4096 audio-token setting is roughly 0.45–0.50 GB, depending on input text length. The 5-layer code-predictor cache is capped at 16 positions and is below 1 MB by the same calculation.
- Reference recording: 5–30 seconds at 24 kHz mono float32 is approximately 0.46–2.75 MiB before temporary copies. The speaker embedding is typically 1024 float32 values (~4 KiB).
- Activations and graph scratch: upstream desktop report estimates ~500 MB but gives no iOS bound. Output PCM at 24 kHz float32 is ~96 KB per second; this spike caps generation at 240 frames (~20 seconds, ~1.9 MB). The app retains a 1024-float (~4 KiB) reference embedding; source audio and encoder scratch are transient.
- Desktop measured context (upstream's report, not this task): peak RSS 3.07 GB with cloning, on Ryzen 5 3600/24 GB RAM using its reported F16 setup. It is not an iPhone measurement.

| iOS planning case | F16 resident peak | Q8_0 resident peak | Q4_K resident peak | Basis |
|---|---:|---:|---:|---|
| Best | ~2.7 GB | ~2.1 GB | ~1.8 GB | Short prompt/output, low graph scratch |
| Likely | ~3.1–3.6 GB | ~2.5–3.0 GB | ~2.2–2.7 GB | Upstream desktop scale, 4096-position F16 KV capacity (~0.45 GB), ~0.5 GB graph scratch |
| Worst | 4.5+ GB | 3.8+ GB | 3.5+ GB | Allocator/backend copies, longer prefill and graph high-water |

Every iOS value is an ESTIMATE, not a measurement. The pinned runtime's desktop report gives 3.141 GB peak RSS with cloning (summary rounds to 3.07 GB), ~2.1 GB model memory, ~200 MB KV, ~500 MB intermediate tensors and ~100 MB audio buffers on Ryzen 5 3600/24 GB. The observed KV is lower than the static 4096-position capacity (~0.45 GB), likely because that run used less context; iOS prefill and allocation are unknown. The converter output sizes and every iPhone peak remain unmeasured. No estimate proves an iPhone can run this model.
