#!/bin/bash
# Build both interfaces without starting or stopping a running Listen instance.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
xcodegen generate --spec "$root/ios/project.yml"
# C and C++ in the packages are optimised (GCC_OPTIMIZATION_LEVEL=3): the local voice
# (MLX) is too slow for speech without it. Swift stays a debug build.
xcodebuild build -project "$root/ios/Listen.xcodeproj" -scheme Listen \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath "$root/ios/build/cli" \
  -clonedSourcePackagesDirPath "$root/ios/build/catalyst/SourcePackages" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= ENABLE_HARDENED_RUNTIME=NO GCC_OPTIMIZATION_LEVEL=3
printf '\nBuilt both modes. Run: %s/bin/listen -cli --help\n' "$root"
