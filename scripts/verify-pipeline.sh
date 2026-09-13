#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  print -u2 'Usage: verify-pipeline.sh <Korean audio longer than 60 seconds> <output workspace folder>'
  exit 2
fi

verificationScriptDirectory=${0:A:h}
exec "$verificationScriptDirectory/run-service-verification.sh" pipeline "$1" "$2"
