#!/usr/bin/env bash
# Build Hackban.app from the Swift package: build/Hackban.app
#   UNIVERSAL=1       build for Apple silicon and Intel
#   SIGN_IDENTITY=…   codesign identity (default: ad-hoc "-")
set -euo pipefail
cd "$(dirname "$0")/.."

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
# The accent colour (Hack Club red) only takes from a compiled asset catalog that Info.plist names.
xcrun actool Resources/Assets.xcassets --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.0 --accent-color AccentColor --output-partial-info-plist "$(mktemp)" >/dev/null
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/" && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist" >/dev/null

codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$app"
echo "Built $app"
