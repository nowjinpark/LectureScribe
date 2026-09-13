#!/bin/zsh
set -euo pipefail

verificationScriptDirectory=${0:A:h}
verificationProjectDirectory=${verificationScriptDirectory:h}
verificationRunner=$1
shift
case "$verificationRunner" in
    transcription) verificationMain=verify-transcription.swift ;;
    pipeline) verificationMain=verify-pipeline.swift ;;
    *) print -u2 'Unknown verification runner'; exit 2 ;;
esac

verificationPackageDirectory=$(mktemp -d /private/tmp/lecturescribe-verification.XXXXXX)
trap 'rm -rf "$verificationPackageDirectory"' EXIT
mkdir -p "$verificationPackageDirectory/Sources/ServiceVerification"
cat > "$verificationPackageDirectory/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "ServiceVerification",
    platforms: [.macOS("26.0")],
    dependencies: [.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0")],
    targets: [.executableTarget(name: "ServiceVerification", dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")])]
)
SWIFT

for verificationSource in TranscriptionService AudioSpeechRegions WhisperAudioChunks SummaryService WorkspaceStore; do
    ln -s "$verificationProjectDirectory/Sources/LectureScribe/$verificationSource.swift" "$verificationPackageDirectory/Sources/ServiceVerification/$verificationSource.swift"
done
ln -s "$verificationScriptDirectory/$verificationMain" "$verificationPackageDirectory/Sources/ServiceVerification/Runner.swift"

verificationSDK="${LECTURESCRIBE_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ -z "${LECTURESCRIBE_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    verificationSDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swift run -c release --disable-sandbox --sdk "$verificationSDK" \
    --package-path "$verificationPackageDirectory" \
    --scratch-path "$verificationProjectDirectory/.build/service-verification" \
    --cache-path "$verificationProjectDirectory/.build/cache" \
    --config-path "$verificationProjectDirectory/.build/config" \
    --security-path "$verificationProjectDirectory/.build/security" \
    ServiceVerification "$@"
