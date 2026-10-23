#!/usr/bin/env bash
# Runs the platform-independent engine tests (macOS or Linux with Swift 5.9+ and libsqlite3-dev).
set -euo pipefail
cd "$(dirname "$0")/.."
swift test "$@"
