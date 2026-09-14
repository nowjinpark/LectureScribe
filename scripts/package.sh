#!/bin/zsh
set -euo pipefail

# Package an already verified build without changing its code signature.
APP_ROOT="${0:A:h:h}"
APP_PATH="${1:-$APP_ROOT/dist/강의노트.app}"
INFO="$APP_PATH/Contents/Info.plist"
PLIST=/usr/libexec/PlistBuddy
[[ -f "$INFO" ]] || { print -u2 '먼저 ./scripts/build.sh로 앱을 빌드하세요.'; exit 1; }
[[ "$($PLIST -c 'Print :CFBundleIdentifier' "$INFO")" == dev.lecturescribe.mac ]] || exit 1
VERSION="$($PLIST -c 'Print :CFBundleShortVersionString' "$INFO")"
MINIMUM_OS="$($PLIST -c 'Print :LSMinimumSystemVersion' "$INFO")"
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || exit 1
[[ "$MINIMUM_OS" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || exit 1
[[ "$(lipo -archs "$APP_PATH/Contents/MacOS/LectureScribe")" == arm64 ]] || {
    print -u2 '이 설치 패키지는 Apple Silicon 앱을 대상으로 합니다.'; exit 1
}
codesign --verify --deep --strict "$APP_PATH"

mkdir -p "$APP_ROOT/dist"
PACKAGE_WORK=$(mktemp -d "$APP_ROOT/dist/.installer.XXXXXXXX")
trap 'rm -rf -- "$PACKAGE_WORK"' EXIT
mkdir -p "$PACKAGE_WORK/root/Applications"
# BOM creation expects decomposed Unicode paths on macOS. This is the same
# visible app name; its NFD spelling avoids pkgbuild losing the Korean parent.
PACKAGE_APP_NAME='강의노트.app'
ditto "$APP_PATH" "$PACKAGE_WORK/root/Applications/$PACKAGE_APP_NAME"

pkgbuild --analyze --root "$PACKAGE_WORK/root" "$PACKAGE_WORK/components.plist"
$PLIST -c 'Set :0:BundleIsRelocatable false' "$PACKAGE_WORK/components.plist"
$PLIST -c 'Set :0:BundleIsVersionChecked true' "$PACKAGE_WORK/components.plist"
$PLIST -c 'Set :0:BundleHasStrictIdentifier true' "$PACKAGE_WORK/components.plist"
$PLIST -c 'Set :0:BundleOverwriteAction upgrade' "$PACKAGE_WORK/components.plist"

pkgbuild --root "$PACKAGE_WORK/root" \
    --component-plist "$PACKAGE_WORK/components.plist" \
    --identifier dev.lecturescribe.mac.pkg --version "$VERSION" \
    --install-location / --ownership recommended \
    "$PACKAGE_WORK/LectureScribe.pkg"

sed -e "s/@VERSION@/$VERSION/g" -e "s/@MINIMUM_OS@/$MINIMUM_OS/g" \
    "$APP_ROOT/Resources/Installer/Distribution.xml.in" > "$PACKAGE_WORK/Distribution.xml"
xmllint --noout "$PACKAGE_WORK/Distribution.xml"

typeset -a SIGNING_OPTIONS
SIGNING_OPTIONS=()
if [[ -n "${LECTURESCRIBE_INSTALLER_IDENTITY:-}" ]]; then
    SIGNING_OPTIONS=(--sign "$LECTURESCRIBE_INSTALLER_IDENTITY" --timestamp)
fi
PACKAGE_NAME="LectureScribe-$VERSION-arm64.pkg"
productbuild --distribution "$PACKAGE_WORK/Distribution.xml" \
    --resources "$APP_ROOT/Resources/Installer/pages" \
    --package-path "$PACKAGE_WORK" "${SIGNING_OPTIONS[@]}" \
    "$APP_ROOT/dist/$PACKAGE_NAME"

# Verify the packaged bytes rather than installing over the running app.
pkgutil --expand-full "$APP_ROOT/dist/$PACKAGE_NAME" "$PACKAGE_WORK/expanded"
PAYLOAD_APP="$PACKAGE_WORK/expanded/LectureScribe.pkg/Payload/Applications/$PACKAGE_APP_NAME"
codesign --verify --deep --strict "$PAYLOAD_APP"
diff -qr "$APP_PATH" "$PAYLOAD_APP"
(
    cd "$APP_ROOT/dist"
    shasum -a 256 "$PACKAGE_NAME" > "LectureScribe-$VERSION-SHA256SUMS.txt"
)
print "설치 파일: $APP_ROOT/dist/$PACKAGE_NAME"
if [[ -z "${LECTURESCRIBE_INSTALLER_IDENTITY:-}" ]]; then
    print '이 패키지는 서명·공증되지 않았습니다. 최초 실행 시 macOS 보안 허용이 필요할 수 있습니다.'
fi
