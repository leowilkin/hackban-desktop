#!/usr/bin/env bash
# Build Hackban.app from the Swift package: build/Hackban.app
#   UNIVERSAL=1       build for Apple silicon and Intel
#   SIGN_IDENTITY=…   codesign identity (default: "Hackban Release" if it's in your keychains, else ad-hoc "-")
#   SIGN_KEYCHAIN=…   only look for the identity in this keychain file (CI imports it into a temporary one)
#   BUILD_NUMBER=…    CFBundleVersion, which the updater compares against releases (default 0: a local build,
#                     which doesn't check for updates on its own)
set -euo pipefail
cd "$(dirname "$0")/.."

build="${BUILD_NUMBER:-0}"
[[ "$build" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER must be a whole number, not '$build'" >&2; exit 1; }

# swiftc links through clang with --sysroot, which doesn't record the SDK version, so the binary says it was
# built against the macOS 14 SDK and macOS 26+ runs it in compatibility mode, without Liquid Glass.
# Handing the clang linker -isysroot makes it record the real SDK version.
sdk="$(xcrun --sdk macosx --show-sdk-path)"
args=(-c release --product Hackban -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk")
if [[ "${UNIVERSAL:-0}" == "1" ]]; then args+=(--arch arm64 --arch x86_64); fi

swift build "${args[@]}"
bin="$(swift build "${args[@]}" --show-bin-path)/Hackban"

linked="$(vtool -show-build "$bin" | awk '$1 == "sdk" { print $2; exit }')"
if [[ "${linked%%.*}" -lt 26 ]]; then
  echo "warning: linked against the macOS $linked SDK, so there's no Liquid Glass on macOS 26+ (build with Xcode 26 or later)" >&2
fi

app=build/Hackban.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Hackban"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$app/Contents/Info.plist"
# The accent colour (Hack Club red) only takes from a compiled asset catalog that Info.plist names.
xcrun actool Resources/Assets.xcassets --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --accent-color AccentColor --output-partial-info-plist "$(mktemp)" >/dev/null
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/" && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist" >/dev/null

# Signed with the same certificate every time, the keychain trusts the signer rather than one build's hash, so it
# doesn't ask again after every update. Ad hoc otherwise. See "Signing" in the README.
identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"Hackban Release"'; then
  identity="Hackban Release"
fi
sign=(--force --deep --sign "${identity:--}")
[[ -n "${SIGN_KEYCHAIN:-}" ]] && sign+=(--keychain "$SIGN_KEYCHAIN")
codesign "${sign[@]}" "$app"
echo "Built $app (signed ${identity:-ad hoc})"
