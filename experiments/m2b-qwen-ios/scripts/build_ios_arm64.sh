#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARTIFACT="$ROOT/artifact"
UPSTREAM="$ROOT/upstream"
mkdir -p "$ARTIFACT"

python3 scripts/prepare_source.py

GGML_BUILD="$UPSTREAM/ggml/build"
QWEN_BUILD="$UPSTREAM/build-ios"

cmake -S "$UPSTREAM/ggml" -B "$GGML_BUILD" \
  -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/ios-arm64-toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_STATIC=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_BACKEND_DL=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_ACCELERATE=OFF \
  -DGGML_BLAS=OFF \
  -DGGML_CUDA=OFF 2>&1 | tee "$ARTIFACT/cmake-ggml-configure.log"
cmake --build "$GGML_BUILD" --parallel --target ggml ggml-base ggml-cpu ggml-metal \
  2>&1 | tee "$ARTIFACT/cmake-ggml-build.log"

cmake -S "$UPSTREAM" -B "$QWEN_BUILD" \
  -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/ios-arm64-toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DQWEN3_TTS_COREML=OFF 2>&1 | tee "$ARTIFACT/cmake-qwen-configure.log"
cmake --build "$QWEN_BUILD" --parallel --target qwen3tts_ios \
  2>&1 | tee "$ARTIFACT/cmake-qwen-build.log"

APP="$ROOT/ios/QwenRuntimeSpike.xcodeproj"
DERIVED="$ROOT/derived-device"
xcodebuild \
  -project "$APP" \
  -scheme QwenRuntimeSpike \
  -sdk iphoneos \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=iOS' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO STRIP_INSTALLED_PRODUCT=NO \
  build 2>&1 | tee "$ARTIFACT/xcodebuild-iphoneos.log"

APP_PRODUCT="$DERIVED/Build/Products/Release-iphoneos/QwenRuntimeSpike.app"
APP_EXECUTABLE="$APP_PRODUCT/QwenRuntimeSpike"
test -s "$APP_EXECUTABLE"

LIBRARIES=(
  "$QWEN_BUILD/libqwen3tts_ios.a"
  "$QWEN_BUILD/libqwen3_tts.a"
  "$QWEN_BUILD/libtext_tokenizer.a"
  "$QWEN_BUILD/libtts_transformer.a"
  "$QWEN_BUILD/libaudio_tokenizer_encoder.a"
  "$QWEN_BUILD/libaudio_tokenizer_decoder.a"
  "$GGML_BUILD/src/libggml.a"
  "$GGML_BUILD/src/libggml-base.a"
  "$GGML_BUILD/src/libggml-cpu.a"
  "$GGML_BUILD/src/ggml-metal/libggml-metal.a"
)

{
  echo "Architecture and platform verification"
  echo "App executable architectures: $(lipo -archs "$APP_EXECUTABLE")"
  lipo -archs "$APP_EXECUTABLE" | grep -Eq '(^| )arm64( |$)'
  APP_PLATFORM="$(xcrun vtool -show-build "$APP_EXECUTABLE")"
  printf '%s\n' "$APP_PLATFORM"
  printf '%s\n' "$APP_PLATFORM" | grep -Eq 'platform IOS([[:space:]]|$)'
  for library in "${LIBRARIES[@]}"; do
    test -s "$library"
    arches="$(lipo -archs "$library")"
    echo "$(basename "$library") architectures: $arches"
    printf '%s\n' "$arches" | grep -Eq '(^| )arm64( |$)'
  done

  echo "Final linked runtime symbols"
  xcrun nm -gU "$APP_EXECUTABLE" | tee "$ARTIFACT/linked-runtime-symbols.txt"
  grep -q 'qwen3_tts_synthesize_with_embedding' "$ARTIFACT/linked-runtime-symbols.txt"
  grep -q 'qwen3_tts_extract_embedding_file' "$ARTIFACT/linked-runtime-symbols.txt"
  grep -q 'ggml_backend_metal_reg' "$ARTIFACT/linked-runtime-symbols.txt"
  grep -q 'AudioTokenizerEncoder' "$ARTIFACT/linked-runtime-symbols.txt"
} 2>&1 | tee "$ARTIFACT/architecture-verification.txt"

mkdir -p "$ARTIFACT/runtime-libraries"
for library in "${LIBRARIES[@]}"; do cp "$library" "$ARTIFACT/runtime-libraries/"; done
cp -R "$APP_PRODUCT" "$ARTIFACT/"
cp "$ROOT/patches/qwen-ios-static.patch" "$ARTIFACT/"
cp "$ROOT/cmake/ios-arm64-toolchain.cmake" "$ARTIFACT/"

cat >> "$ARTIFACT/build-metadata.txt" <<EOF
Qwen3-TTS official reference revision: 022e286b98fbec7e1e916cb940cdf532cd9f488e
Qwen3-TTS model revision (not downloaded by this build): dab70521e0956e3db91fb887d36c9a07d21ebc0b
qwen3-tts.cpp revision: $(git -C "$UPSTREAM" rev-parse HEAD)
GGML gitlink revision: $(git -C "$UPSTREAM" rev-parse HEAD:ggml)
Target: CMAKE_SYSTEM_NAME=iOS, iphoneos, arm64
Runtime execution: NOT TESTED
Model weights: not downloaded or included
EOF

echo "Verified iPhoneOS ARM64 runtime build and linked spike app." | tee -a "$ARTIFACT/architecture-verification.txt"
