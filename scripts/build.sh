#!/bin/zsh
set -euo pipefail
APP_ROOT="${0:A:h:h}"
cd "$APP_ROOT"
export CLANG_MODULE_CACHE_PATH="$APP_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$APP_ROOT/.build/clang-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$APP_ROOT/dist"
SDK_PATH="${LECTURESCRIBE_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
# Some Command Line Tools ship a preview 27 SDK without its SwiftUI macro plugin.
if [[ -z "${LECTURESCRIBE_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift build --disable-sandbox --sdk "$SDK_PATH" -c release --cache-path "$APP_ROOT/.build/cache" --config-path "$APP_ROOT/.build/config" --security-path "$APP_ROOT/.build/security"
BIN_DIR=$(swift build --disable-sandbox --sdk "$SDK_PATH" -c release --show-bin-path --cache-path "$APP_ROOT/.build/cache" --config-path "$APP_ROOT/.build/config" --security-path "$APP_ROOT/.build/security")
APP_PATH="$APP_ROOT/dist/강의노트.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/LectureScribe" "$APP_PATH/Contents/MacOS/LectureScribe"
cp "$APP_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
swift "$APP_ROOT/scripts/make-icon.swift" "$APP_ROOT/.build/AppIcon.iconset"
iconutil -c icns "$APP_ROOT/.build/AppIcon.iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
print "앱 생성 완료: $APP_PATH"
