# Gate B2 true-device checklist

## Install the independent spike

1. Download the `QwenIOSSpike-unsigned-IPA` workflow artifact ZIP and extract `QwenIOSSpike-unsigned.ipa`.
2. On Windows, connect the iPhone, open Sideloadly, select the extracted IPA, enter the Apple ID Sideloadly requires, and press Start. This signs the unsigned IPA for installation; it does not add signing credentials to the repository.
3. If iOS asks, trust the developer app under **Settings → General → VPN & Device Management**.
4. Prepare the local `Qwen3-TTS-0.6B` folder as described in `model/README.md`. Put it in Files on the iPhone (for example, AirDrop the folder from a Mac or copy it using Files and local device storage).
5. Open **Qwen iOS Spike** → **Import model package from Files** → choose the `Qwen3-TTS-0.6B` folder. Wait for import to finish; the app copies it into private local storage.
6. Choose **CPU** or **Metal**, tap **Load model**, record a 5–10 second reference or choose WAV/M4A, tap **Prepare reference embedding**, enter new text, tap **Generate local speech**, then **Play generated audio**.

## Four minimum cloning checks

Run each case with CPU, then unload the model, switch to Metal, reload, and repeat. Record success/failure, actual backend, load/prepare/generation times, output duration, RTF, physical footprint, memory warnings, crash/thermal behavior, and whether the speaker similarity is acceptable:

1. Chinese reference → new Chinese text
2. Chinese reference → new English text
3. English reference → new English text
4. English reference → new Chinese text

Finally enable Airplane Mode and repeat load, reference preparation, generation, and playback. Record iPhone model, iOS version, IPA commit, and `manifest.json` hashes.

The transcript field is diagnostic-only and is not passed to this x-vector/speaker-embedding runtime. These checks are not evidence of the official reference-audio-plus-transcript conditioning path. Do not report any device, voice-cloning, CPU, Metal, offline, memory, or performance result until the user runs these checks on an iPhone.
