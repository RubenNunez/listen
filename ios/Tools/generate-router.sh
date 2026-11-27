#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Build the pinned official generator first, or point at another compatible binary.
generator=$(command -v "${LISTEN_GRPC_GENERATOR:-protoc-gen-grpc-swift-2}") || {
  printf 'Build protoc-gen-grpc-swift-2 2.5.0 and set LISTEN_GRPC_GENERATOR to its executable.\n' >&2
  exit 1
}
mkdir -p ios/Listen/Router/Generated
protoc -I proto \
  --swift_out=ios/Listen/Router/Generated \
  --swift_opt=Visibility=Internal,FileNaming=DropPath \
  --plugin="protoc-gen-grpc-swift-2=$generator" \
  --grpc-swift-2_out=ios/Listen/Router/Generated \
  --grpc-swift-2_opt=Visibility=Internal,Client=true,Server=false,FileNaming=DropPath \
  proto/listen/router/v1/router.proto
