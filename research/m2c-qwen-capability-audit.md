# M2-C Qwen capability audit

Audit scope: official Qwen3-TTS 0.6B Base at `dab70521e0956e3db91fb887d36c9a07d21ebc0b`, `predict-woo/qwen3-tts.cpp` at `b3ba14077cf1b3e11b86e5f84aa9184605c89b28`, GGML at `3af5f5760e19a96427f5f7a93b79cbdf3d4b265b`, the formal iOS adapter, and user-reported iPhone evidence. Do not conflate the official Python ICL path with the C++ x-vector path.

## Capability matrix

| Capability | Official 0.6B Base | Pinned `qwen3-tts.cpp` | Formal iOS adapter | iPhone evidence | Product decision |
|---|---|---|---|---|---|
| `voice_clone` | Supported. Base accepts reference audio; official API also supports reference transcript/ICL mode and x-vector-only mode. | Supported with a reference-audio-derived ECAPA x-vector. | Supported from a saved Voice reference; adapter derives a disposable in-memory embedding. | PASS: user reported CPU load, live reference preparation and Chinese generation; voice similarity was described as close. | Show saved-voice selection and Generate. |
| `voice_design` | Not a capability of this exact Base checkpoint; Qwen offers separate VoiceDesign checkpoints. | Unsupported by this public C API. | Unsupported. | Not tested. | No control. |
| `timbre_control` | No independent timbre control exposed by Base; reference conditioning selects the identity. | No timbre adjustment input. | Unsupported. | No independent control tested. | No slider. |
| `emotion_control` | No emotion control exposed by the Base clone API. | No emotion/instruction field in the C API. | Unsupported. | Not tested. | No control. |
| `accent_control` | The Qwen family is multilingual and describes dialectal voice profiles, but Base exposes language selection rather than a dedicated accent setting. | No accent or dialect argument. | Unsupported. | Not tested. | No control. |
| `speed_control` | No user-facing speech-rate control identified for this Base path. | No speed argument. | Unsupported. | Not tested. | No control. |
| `instruction_control` | Instruction-driven voice control is associated with other model variants/API paths, not this Base clone call. | No instruction argument. | Unsupported. | Not tested. | No control. |
| `language_selection` | Supported for 10 languages. | C API carries `language_id`; CLI maps the same 10 language IDs. | Supported for English and Chinese in this first UI. | Chinese generation PASS per user report; English not reported as device-tested. | Show only English and Chinese for now. |
| `dialect_control` | No explicit Base dialect selector in the reviewed clone API. | Unsupported. | Unsupported. | Not tested. | No control. |
| `reference_transcript_conditioning` | Supported in official ICL mode; reference text is required for that mode. | Unsupported; reference API extracts an x-vector and has no transcript input. | Unsupported; transcript is not collected or claimed. | The supplied test evidence is x-vector cloning only. | Do not label this complete ICL cloning. |

The product has no Voice Shaping or Expression controls enabled in this slice. The only generation choices are a saved Voice, output language (English or Chinese), text, Generate, playback and Save Audio. This avoids exposing controls the active runtime cannot execute.

## Renderer pack and asset boundary

The pack manifest records pack/renderer identity, variant, version, compatibility version, required files and SHA-256 values, capability states, languages/dialects, source/runtime revisions, and internal precision metadata. The product surface only says “local voice pack” / “local voice engine”; it does not show Qwen, GGUF, or precision to ordinary users.

Pack installation lives under Application Support `RendererPacks/LocalVoice`. Voice reference and generated speech stay in the existing managed audio store. Renderer-derived speaker embeddings stay in memory and can be rebuilt from the saved reference. Replacing or removing pack files does not modify Voice or Audio records.

## True-device facts supplied for M2-B CPU gate

These are user-reported physical-iPhone results, not CI results:

- Spike IPA installed; model folder imported and copied into app-private storage.
- CPU model load: 662 ms. A short live reference was prepared and used for x-vector cloning.
- Chinese speech generated offline; user described the voice match as close and naturalness as not stiff.
- One run: 7.90 s generated audio, 16,808 ms generation, RTF 2.13, physical footprint 3,227 MB, one memory warning.
- Record, prepare, and generation worked in Airplane Mode.
- Metal attempt returned `Metal unavailable: runtime selected MTL`; this remains an optimization issue and is not used by the formal CPU path.

No new true-device run is claimed for the formal app, English output, Q8, or the formal app's persistence/playback flow.

## Q8 candidate

Candidate repository: `TeALO/qwen3-tts-gguf`, locked repository revision `ee2fe152f14b4ec8b06c393969c3416246366833`; declared base model `Qwen/Qwen3-TTS-12Hz-0.6B-Base`, Apache-2.0. Its card says the files were produced with qwen3-tts.cpp's own converter scripts and verified on desktop, but does not name an exact converter commit or exact official source revision. This remains a provenance caveat and is recorded in the candidate manifest.

At that revision, the declared Q8 main model is 1,342,925,920 bytes (SHA-256 `c6ed09d25e6ce06d5804233fcce3f0c62661cc12ab5549bc25edf3d61f0dd4f8`) and the codec file is 273,327,360 bytes (SHA-256 `ce396a0115b9e86c15c6a135c519952e3fcc7aaab91802fff0173d75f027eabb`). The model card calls the codec Q8_0 but names it `qwen3-tts-tokenizer-f16.gguf`; verify its internal GGUF tensor types before treating it as mixed precision. The main filename matches the pinned runtime's Q8 lookup path.

Candidate pack is not a replacement for the F16 baseline. Desktop synthesis and phone A/B remain separate validation gates; no model output or quality claim is asserted by hash validation alone.
