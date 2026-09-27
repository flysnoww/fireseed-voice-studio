#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="$ROOT/upstream"
PLATFORM="${1:-}"

case "$PLATFORM" in
  device)
    SDK=iphoneos
    TOOLCHAIN="$ROOT/cmake/ios-arm64-toolchain.cmake"
    ;;
  simulator)
    SDK=iphonesimulator
    TOOLCHAIN="$ROOT/cmake/ios-simulator-arm64-toolchain.cmake"
    ;;
  *)
    echo "Usage: $0 device|simulator" >&2
    exit 2
    ;;
esac

python3 "$ROOT/scripts/prepare_source.py"
GGML_BUILD="$ROOT/build/formal-$SDK/ggml"
QWEN_BUILD="$ROOT/build/formal-$SDK/qwen"
SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"

# Let separate simulator/device CMake trees coexist without changing the pinned upstream revision.
python3 - "$UPSTREAM/CMakeLists.txt" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
default = 'set(GGML_BUILD_DIR "${GGML_DIR}/build")'
configured = 'set(GGML_BUILD_DIR "${GGML_DIR}/build" CACHE PATH "GGML build directory")'
if configured not in source:
    if source.count(default) != 1:
        raise SystemExit("Pinned CMake GGML build-directory line changed; refusing an unreviewed edit.")
    path.write_text(source.replace(default, configured), encoding="utf-8")
PY

cmake -S "$UPSTREAM/ggml" -B "$GGML_BUILD" \
  -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DGGML_STATIC=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_BACKEND_DL=OFF \
  -DGGML_METAL=OFF \
  -DGGML_ACCELERATE=OFF \
  -DGGML_BLAS=OFF \
  -DGGML_CUDA=OFF
cmake --build "$GGML_BUILD" --parallel --target ggml ggml-base ggml-cpu

cmake -S "$UPSTREAM" -B "$QWEN_BUILD" \
  -G "Unix Makefiles" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_BUILD_DIR="$GGML_BUILD" \
  -DQWEN3_TTS_COREML=OFF
cmake --build "$QWEN_BUILD" --parallel --target qwen3tts_ios

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
)
for library in "${LIBRARIES[@]}"; do
  test -s "$library"
  lipo -archs "$library" | grep -Eq '(^| )arm64( |$)'
done

echo "Verified $PLATFORM ARM64 static renderer libraries from qwen3-tts.cpp $(git -C "$UPSTREAM" rev-parse HEAD)."
