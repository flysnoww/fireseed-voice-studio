# iOS compatibility static audit

Audit target: `predict-woo/qwen3-tts.cpp` `b3ba14077cf1b3e11b86e5f84aa9184605c89b28` and its `ggml` submodule `3af5f5760e19a96427f5f7a93b79cbdf3d4b265b`. This is source inspection only; no iOS build was run.

| Component / source | Evidence | iOS status | Expected action / risk |
|---|---|---|---|
| Pipeline / `src/qwen3_tts.cpp` | Standard C++17 containers/chrono plus platform-selected process-memory headers. | **IOS LIKELY** | Core inference is model/platform neutral; compile and measure the actual iOS target. |
| Tensor engine / GGML | Pinned C/C++ GGML; CPU, Metal, Accelerate options. CMake's native tuning must be disabled for cross-compilation. | **REQUIRES CHANGES** | Build arm64 with `GGML_NATIVE=OFF`; do not retain `-march=native`. |
| Text tokenizer / `src/text_tokenizer.cpp` | C++ BPE over GGUF vocab and merges; no OS framework. | **IOS LIKELY** | No platform-specific source found. Functional fidelity still needs multilingual test vectors. |
| Speaker encoder / `src/audio_tokenizer_encoder.cpp` | GGML CPU tensor ops, C++ math/containers; no explicit OS framework. | **IOS LIKELY** | Verify ARM64 kernels, memory, and audio equivalence in Xcode/device. |
| Transformer/KV cache / `src/tts_transformer.cpp` | GGML graphs and F16 KV buffers; optional `coreml_code_predictor.mm` chosen by `APPLE`. | **REQUIRES CHANGES** | Baseline spike disables CoreML; compile GGML path first. Runtime currently uses shared backend preference and CPU fallback. |
| Decoder / `src/audio_tokenizer_decoder.cpp` | GGML CPU/selected backend and C++ math. | **IOS LIKELY** | Verify complete decoder on device; upstream performance evidence is desktop-only. |
| Audio reader/writer / `src/qwen3_tts.cpp` | `fopen/fread/fwrite/fseek`, RIFF parser, mono averaging, linear resampling. | **IOS LIKELY** | POSIX/C stdio exists on iOS; parser is WAV-only. Spike supplies local WAV via AVFoundation. |
| Process memory / `src/qwen3_tts.cpp` | `#ifdef __APPLE__`, `mach/mach.h`, `task_info`, `TASK_VM_INFO.phys_footprint`; no `TARGET_OS_OSX` or `TARGET_OS_IOS` guard. | **UNKNOWN** | Xcode must confirm public header/API availability and iPhone behavior. Failure should be isolated/guarded without dropping the inference path. |
| C bridge / `src/qwen3tts_c_api.cpp` | Under `__APPLE__`, uses `objc/objc.h`, `objc/message.h`, `objc_msgSend`, and `NSAutoreleasePool`; links Objective-C runtime/Foundation assumptions. | **IOS LIKELY** | iOS ships Objective-C runtime/Foundation, but build and background-thread autorelease behavior remain unverified. Spike links Foundation and libobjc. |
| CoreML bridge / `src/coreml_code_predictor.mm` | Objective-C++ imports CoreML/Foundation and sets `MLComputeUnitsCPUAndNeuralEngine`; CMake comment explicitly says “macOS only”. | **MACOS ONLY** for the existing upstream path | Disable for first iOS proof. Apple Core ML is an iOS framework, but this repo's converter/runtime combination is not claimed portable or iOS-tested. |
| CoreML model conversion / `scripts/setup_pipeline_models.py` | `--coreml auto` means Darwin; explicit CoreML request on non-macOS errors; README describes macOS. | **MACOS ONLY** | Do not make CoreML conversion a dependency for the iOS GGML baseline. |
| Metal framework / `ggml/src/ggml-metal/CMakeLists.txt` | Links Metal + MetalKit; target includes `.m` Objective-C sources; no macOS-only runtime calls in the observed CMake branch. | **LIKELY PORTABLE** | Apple documents Metal/MetalKit across iPhone and Mac. This does not prove these GGML kernels build/run on iOS. |
| Metal embedded shader path / same file | `GGML_METAL_EMBED_LIBRARY` embeds MSL source in an assembly section; runtime source compilation is an Apple Metal API path. | **LIKELY PORTABLE** | Use embedded mode so the alternative `xcrun -sdk macosx metal` path is avoided. Validate Xcode ARM64 target and runtime shader compilation on iPhone. |
| Metal integration / qwen `CMakeLists.txt` | It only detects `ggml/build/src/ggml-metal/libggml-metal.dylib`, assumes a dylib, and uses macOS-focused docs. | **REQUIRES CHANGES** | Spike patch also recognizes a static `.a`; link Metal frameworks explicitly. Backend selection must be observed from runtime device name. |
| CPU SIMD / GGML | Apple CMake defaults `GGML_NATIVE` on unless cross-compiling; GGML contains ARM and x86 implementation families. | **IOS LIKELY** | Build arm64 with native host tuning off. No x86-specific branch should be selected for iphoneos/arm64, but confirm generated compile commands. |
| Accelerate / GGML CMake | `GGML_ACCELERATE` defaults on for Apple; `GGML_BLAS` defaults on for Apple. Apple documents Accelerate/BLAS across iOS and macOS. | **IOS LIKELY** | Initial spike disables Accelerate and BLAS to isolate the CPU/Metal baseline. Re-enable only after comparing device results. |
| Threads | qwen CMake uses `find_package(Threads REQUIRED)` and `Threads::Threads`; GGML uses C++/system threading. | **IOS LIKELY** | iOS pthread/C++ threads are expected; check the actual link and runtime under the app sandbox. |
| Filesystem | Standard C/C++ file APIs; some `sys/stat.h`. No model-path sandbox abstraction in upstream. | **IOS LIKELY** | Use Files picker security-scoped local folder and keep scope active while model files are loaded. iCloud-only files must be downloaded before Airplane-mode tests. |
| mmap / dlopen | No direct `mmap`, `dlopen`, `fork`, or `exec` call found in qwen inference sources. GGML dynamic backend loading is avoidable. | **IOS LIKELY** with static config | Build `GGML_BACKEND_DL=OFF`, `BUILD_SHARED_LIBS=OFF`; preparation scripts use subprocess only before install, never during inference. |
| Python / PyTorch | README and conversion scripts use Python, torch, safetensors, NumPy, gguf, Hugging Face Hub; README states no Python/PyTorch at inference. | **NOT IN DEVICE RUNTIME** | Keep Python in model download/conversion only. Verify the signed test app contains no Python runtime. |
| Audio UI framework | Spike uses AVFoundation for record/playback and WAV creation; it is independent of runtime C++ audio decode. | **IOS LIKELY** | Native framework, but recording conversion and file-picker security scope require Xcode/device checks. |

## Static feasibility conclusion

The portable C++/GGML CPU core is a plausible iOS port. The repository does not provide an iOS project, iOS toolchain config, static C ABI target, or demonstrated iPhone artifact. The exact necessary build-system changes are prepared in `patches/qwen-ios-static.patch` and `cmake/ios-arm64-toolchain.cmake`; they are not verified until run with Xcode. CoreML is excluded from the first build, not equated with general iOS support. Metal's API and embedded-source strategy are likely portable, while the existing Qwen CMake detection and macOS SDK shader branch require changes.

### Metal-specific answer

- **General Apple API or macOS-only?** GGML links Metal, MetalKit, and Foundation and uses Objective-C sources. Apple's published frameworks include iOS, but this Qwen/GGML combination is not device-verified.
- **Shader suitability?** Pinned GGML source is MSL and its embedded path assembles shader source into the library for runtime Metal library creation. Plausible on iOS; no iPhone shader compile/run evidence.
- **Buffer/memory API?** Uses Metal device/buffer APIs. The platform exposes Metal resources, but this audit has no iOS allocation evidence or safe peak bound.
- **Build path?** GGML_METAL_EMBED_LIBRARY=ON embeds shader source. With it off, pinned CMake invokes xcrun -sdk macosx metal/metallib, a MACOS ONLY build path. The spike selects embedded mode.
- **x86/mac-specific branch?** GGML selects CPU sources through target/compiler architecture checks; this recipe targets arm64 and sets GGML_NATIVE=OFF. No x86 runtime dependency was found in the inspected app path. Verify generated compile commands and archive architectures on the Mac.
- **Metal result:** **LIKELY PORTABLE** for embedded shader use. Qwen's dylib assumption **REQUIRES CHANGES**. Device compilation/runtime remain unverified.

### Platform-call scan summary

- `#ifdef __APPLE__`: memory code in `qwen3_tts.cpp` and autorelease pool in `qwen3tts_c_api.cpp`; CoreML `.mm` has `#if defined(__APPLE__)`.
- `TARGET_OS_OSX` / `TARGET_OS_IOS`: not used to distinguish targets in the inspected Qwen sources.
- `AppKit`, `UIKit`, `AVFoundation`: not used by inference sources. Spike UI uses UIKit/AVFoundation.
- `CoreML`, `Metal`, `MetalPerformanceShaders`, `Accelerate`: CoreML in optional bridge; Metal/MetalKit in GGML; Accelerate selected by GGML option; no MPS import in Qwen runtime.
- `mmap`, `dlopen`, `fork`, `exec`, `system`, Python subprocess: no such calls in the inference pipeline. The preparation script launches the converter as an external build-time process.
