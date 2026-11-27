#!/bin/sh
# Builds Listen as a Mac Catalyst app, signed to run locally (no developer
# account, no provisioning), and opens it. The Mac's real microphone and
# Apple's on-device transcriber are used, unlike in the iOS simulator.
set -e
cd "$(dirname "$0")/.."
Tools/generate-project.sh >/dev/null
# C and C++ in the packages are optimised (GCC_OPTIMIZATION_LEVEL=3): the local voice
# (MLX) is too slow for speech without it. Swift is also optimized for local voices.
xcodebuild -project Listen.xcodeproj -scheme Listen \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build/catalyst \
  TARGETED_DEVICE_FAMILY=1,2 CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= ENABLE_HARDENED_RUNTIME=NO \
  GCC_OPTIMIZATION_LEVEL=3 SWIFT_OPTIMIZATION_LEVEL=-O \
  build
# Conversations are recorded into the project's runs/ folder (ignored by git),
# so they can be replayed with Tools/transcribe-check/replay.sh.
mkdir -p ../runs
# A running copy would only come to the front and keep the old code: end it first.
pkill -f "Debug-maccatalyst/Listen.app/Contents/MacOS/Listen" 2>/dev/null && sleep 1 || true
open build/catalyst/Build/Products/Debug-maccatalyst/Listen.app --args -runsFolder "$(cd ../runs && pwd)"
