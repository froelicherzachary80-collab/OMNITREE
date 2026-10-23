#!/usr/bin/env bash
# Generates App/MultiverseTree.xcodeproj on a Mac. Requires Xcode 26+ and XcodeGen (free).
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null; then
  echo "Installing XcodeGen via Homebrew…"
  brew install xcodegen
fi
(cd App && xcodegen generate)
echo "Open App/MultiverseTree.xcodeproj, choose your Team under Signing & Capabilities, select your iPhone and press Run."
