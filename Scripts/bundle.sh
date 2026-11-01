#!/usr/bin/env bash
# Build Hackban.app from the Swift package: build/Hackban.app
#   UNIVERSAL=1       build for Apple silicon and Intel
#   SIGN_IDENTITY=…   codesign identity (default: ad-hoc "-")
set -euo pipefail
cd "$(dirname "$0")/.."

args=(-c release --product Hackban)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then args+=(--arch arm64 --arch x86_64); fi

swift build "${args[@]}"
bin="$(swift build "${args[@]}" --show-bin-path)/Hackban"

app=build/Hackban.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Hackban"
cp Resources/Info.plist "$app/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/" && \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist" >/dev/null

codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$app"
echo "Built $app"
