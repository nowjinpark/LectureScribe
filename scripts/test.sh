#!/bin/zsh
set -euo pipefail
APP_ROOT="${0:A:h:h}"
cd "$APP_ROOT"
export CLANG_MODULE_CACHE_PATH="$APP_ROOT/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$APP_ROOT/.build/clang-cache"
SDK_PATH="${LECTURESCRIBE_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ -z "${LECTURESCRIBE_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
PLUGIN_DIR="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
EXTRA_FLAGS=()
if [[ -d "$PLUGIN_DIR" ]]; then
    EXTRA_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGIN_DIR")
fi
swift test --disable-sandbox --sdk "$SDK_PATH" --cache-path "$APP_ROOT/.build/cache" --config-path "$APP_ROOT/.build/config" --security-path "$APP_ROOT/.build/security" "${EXTRA_FLAGS[@]}"
