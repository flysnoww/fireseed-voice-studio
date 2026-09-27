# Build the isolated iOS runtime spike on macOS

These are preparation instructions, not a successful build record. Do not copy model files into the formal Voice Studio app.

## Requirements

- macOS with Xcode and iPhoneOS SDK selected, CMake 3.20+, Command Line Tools, Python 3.12, and Git.
- At least 12 GB free on Mac for source, conversion intermediates, F16 GGUFs, and build output; several GB free on the iPhone for local model files and runtime allocations.
- A code-signing team for device installation. The spike does not need signing secrets in GitHub.

## 1. Fetch immutable sources and prepare model

From the repository root:

```bash
cd experiments/m2b-qwen-ios
python3 scripts/prepare_source.py
python3 -m venv model/.venv
model/.venv/bin/python -m pip install -r model/requirements-conversion.txt
GGUF_PYTHONPATH="$PWD/upstream/ggml/gguf-py" model/.venv/bin/python scripts/prepare_model.py --python "$PWD/model/.venv/bin/python"
```

`prepare_source.py` asserts both full Git revisions before applying the spike patch. `prepare_model.py` downloads the exact HF revision, verifies both large input hashes, runs the pinned upstream F16 conversion with CoreML disabled, and writes a local ignored hash/version manifest.

## 2. Build GGML static for physical iPhone ARM64

CMake's toolchain manual recommends the Xcode generator for Apple-device builds and also allows Unix Makefiles/Ninja when device CPU selection and signing are handled by the project. This recipe fixes the target at iphoneos/arm64 and signs only the app through Xcode. If this CMake configuration fails or generates a different archive layout, adjust the spike from the actual Mac diagnostics.

The qwen top-level CMake assumes GGML's build output lives in `upstream/ggml/build`, so use this directory exactly. The Unix Makefiles generator keeps the paths expected by the upstream top-level CMake and avoids Xcode's per-configuration archive subdirectories.

```bash
cmake -S upstream/ggml -B upstream/ggml/build \
  -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/cmake/ios-arm64-toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_STATIC=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_BACKEND_DL=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_ACCELERATE=OFF \
  -DGGML_BLAS=OFF \
  -DGGML_CUDA=OFF
cmake --build upstream/ggml/build --parallel --target ggml ggml-base ggml-cpu ggml-metal
```

Embedded Metal mode is selected to avoid the upstream alternative's hard-coded `xcrun -sdk macosx metal` shader compilation. The UI offers CPU and Metal attempts. CPU sets the pinned runtime's explicit `cpu` mode. Metal uses its `auto` GPU-preferred mode, then verifies the actual backend registry is Metal and reports Metal unavailable if it fell back. The pinned runtime has no dedicated Metal mode; the spike does not claim one.

## 3. Build qwen static libraries and C API

The small local patch removes `-march=native` only for iOS cross-compilation, makes qwen's Metal detection accept the expected static backend archive, adds a static C ABI target, and exposes the runtime-selected GGML device name for spike diagnostics.

```bash
cmake -S upstream -B upstream/build-ios \
  -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/cmake/ios-arm64-toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DQWEN3_TTS_COREML=OFF
cmake --build upstream/build-ios --parallel --target qwen3tts_ios
```

Confirm that all archives are arm64 device archives and exist at these expected paths before opening Xcode:

```text
upstream/build-ios/libqwen3tts_ios.a
upstream/build-ios/libqwen3_tts.a
upstream/build-ios/libtext_tokenizer.a
upstream/build-ios/libtts_transformer.a
upstream/build-ios/libaudio_tokenizer_encoder.a
upstream/build-ios/libaudio_tokenizer_decoder.a
upstream/ggml/build/src/libggml.a
upstream/ggml/build/src/libggml-base.a
upstream/ggml/build/src/libggml-cpu.a
upstream/ggml/build/src/ggml-metal/libggml-metal.a
```

If the actual CMake archive paths differ, fix only the Xcode `LIBRARY_SEARCH_PATHS` to match the generated files; do not copy Mac or simulator libraries into the app.

## 4. Build and install the Xcode spike app

Open `ios/QwenRuntimeSpike.xcodeproj`, choose the `QwenRuntimeSpike` scheme and an actual iPhone destination, set a signing team, then Build and Run. The project links the static archives above. The app's folder picker expects a **local on-device** directory containing the two generated `.gguf` files. Keep the model directory security scope open until unload.

Build-only CLI equivalent after setting the team in Xcode:

```bash
xcodebuild -project ios/QwenRuntimeSpike.xcodeproj \
  -scheme QwenRuntimeSpike \
  -destination 'platform=iOS,id=<CONNECTED_IPHONE_UDID>' \
  -configuration Debug \
  build
```

## 5. Interpretation

- Record app build result, selected GGML backend name, load/prepare/generate ms, output duration/RTF, and physical footprint/memory warnings.
- Run with Metal and CPU; check the actual backend registry reported by the app. A CPU success does not prove Metal. A Metal backend report does not prove correct cloning.
- Reference transcript is collected for test notes only because this C++ runtime ignores it. Do not describe the run as official transcript-conditioned ICL cloning.
- Airplane-mode test is required after model files are local. No inference path should call the network.

## Automated Gate B1

The repository's isolated `.github/workflows/qwen-ios-spike.yml` workflow runs `scripts/build_ios_arm64.sh` on an Apple Silicon GitHub macOS runner. It compiles the GGML CPU/Metal archives and all Qwen runtime libraries against the iPhoneOS SDK, links them through the spike app's Xcode target, and verifies arm64 plus the executable's Mach-O `platform IOS` load command. `QwenIOSSpike-build` contains the app build, runtime archives, toolchain/patch, source pins, and verification log. It contains no model weights or audio. This is compile/link evidence only, not runtime/device validation.
