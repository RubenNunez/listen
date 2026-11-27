#!/bin/bash
# Native regression suite and core settings/topic flows in both appearances.
set -euo pipefail
simulator_id="${1:?Usage: check-settings.sh <booted-iPhone-simulator-UUID>}"
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$project_root"
output="runs/settings-check-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$output"
original_appearance="$(xcrun simctl ui "$simulator_id" appearance)"
case "$original_appearance" in light|dark) ;; *) echo "Could not read simulator appearance" >&2; exit 1 ;; esac
trap 'xcrun simctl ui "$simulator_id" appearance "$original_appearance" >/dev/null 2>&1 || true' EXIT

xcodegen generate --spec ios/project.yml > "$output/generate.log" 2>&1
for appearance in light dark; do
    xcrun simctl ui "$simulator_id" appearance "$appearance"
    echo "Checking Settings in $appearance appearance; results: $output"
    test_targets=(-only-testing:ListenUITests/SettingsFlowUITests -only-testing:ListenUITests/TopicEditingUITests -only-testing:ListenUITests/VoiceSetupUITests)
    if [ "$appearance" = light ]; then test_targets+=(-only-testing:ListenTests); fi
    xcodebuild test -project ios/Listen.xcodeproj -scheme Listen \
        -destination "platform=iOS Simulator,id=$simulator_id" \
        -derivedDataPath ios/build/meeting-sim \
        -clonedSourcePackagesDirPath ios/build/catalyst/SourcePackages \
        -disableAutomaticPackageResolution -skipPackageUpdates \
        -parallel-testing-enabled NO "${test_targets[@]}" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
        PROVISIONING_PROFILE_SPECIFIER= ENABLE_HARDENED_RUNTIME=NO \
        -resultBundlePath "$output/$appearance.xcresult" > "$output/$appearance.log" 2>&1
done
echo "Settings checks passed in light and dark; original appearance restored on exit."
