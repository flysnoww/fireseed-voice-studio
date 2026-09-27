#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: package_unsigned_ipa.sh path/to/QwenRuntimeSpike.app output.ipa}"
IPA="${2:?usage: package_unsigned_ipa.sh path/to/QwenRuntimeSpike.app output.ipa}"
test -d "$APP"
test -s "$APP/QwenRuntimeSpike"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")" = "org.fireseed.QwenRuntimeSpike"
test ! -e "$APP/_CodeSignature"
test ! -e "$APP/embedded.mobileprovision"
lipo -archs "$APP/QwenRuntimeSpike" | grep -Eq '(^| )arm64( |$)'
xcrun vtool -show-build "$APP/QwenRuntimeSpike" | grep -Eq 'platform IOS([[:space:]]|$)'
if find "$APP" -type f \( -name '*.gguf' -o -name '*.safetensors' -o -name '*.pt' \) | grep -q .; then
  echo "Model weights must not be included in the Spike IPA." >&2
  exit 1
fi

TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT
mkdir -p "$TEMP_ROOT/Payload"
ditto "$APP" "$TEMP_ROOT/Payload/QwenRuntimeSpike.app"
mkdir -p "$(dirname "$IPA")"
(cd "$TEMP_ROOT" && /usr/bin/zip -qry "$IPA" Payload)
unzip -Z1 "$IPA" | grep -q '^Payload/QwenRuntimeSpike.app/Info.plist$'
unzip -Z1 "$IPA" | grep -q '^Payload/QwenRuntimeSpike.app/QwenRuntimeSpike$'
echo "Unsigned iPhoneOS arm64 IPA: $IPA"
