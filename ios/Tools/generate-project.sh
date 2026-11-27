#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
xcodegen generate
mkdir -p Listen.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved Listen.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
