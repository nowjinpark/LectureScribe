#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
    print -u2 'Usage: verify-transcription.sh <audio file> <output folder> [locale, default ko-KR]'
    exit 2
fi

transcriptionScriptDirectory=${0:A:h}
exec "$transcriptionScriptDirectory/run-service-verification.sh" transcription "$@"
