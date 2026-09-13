#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  print -u2 'Usage: verify-pipeline.sh <Korean audio longer than 60 seconds> <output workspace folder>'
  exit 2
fi

verificationScriptDirectory=${0:A:h}
verificationProjectDirectory=${verificationScriptDirectory:h}
verificationBuildDirectory=$(mktemp -d /private/tmp/lecturescribe-pipeline.XXXXXX)
trap 'rm -rf "$verificationBuildDirectory"' EXIT

xcrun swiftc -swift-version 6 -target arm64-apple-macosx26.0 \
  -module-cache-path "$verificationBuildDirectory/module-cache" \
  "$verificationProjectDirectory/Sources/LectureScribe/TranscriptionService.swift" \
  "$verificationProjectDirectory/Sources/LectureScribe/SummaryService.swift" \
  "$verificationProjectDirectory/Sources/LectureScribe/WorkspaceStore.swift" \
  "$verificationScriptDirectory/verify-pipeline.swift" \
  -o "$verificationBuildDirectory/verify-pipeline"

"$verificationBuildDirectory/verify-pipeline" "$1" "$2"
