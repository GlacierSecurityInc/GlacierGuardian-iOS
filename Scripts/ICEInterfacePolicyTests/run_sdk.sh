#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
framework_dir="${1:?Pass the directory containing the macOS WebRTC.framework from the pinned XCFramework}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
policy_dir="$repo_dir/Glacier/Classes/Controllers/ICEInterfacePolicy"
xcrun clang -fobjc-arc -fmodules -I "$policy_dir" -F "$framework_dir" \
  "$policy_dir/GlacierICEInterfacePolicy.m" "$policy_dir/GlacierICEInterfaceFilter.c" \
  "$policy_dir/GlacierICESymbolRebinding.c" "$repo_dir/Scripts/ICEInterfacePolicyTests/sdk_integration.m" \
  -framework Foundation -framework Network -framework WebRTC -Wl,-rpath,"$framework_dir" -o "$test_dir/sdk-test"
"$test_dir/sdk-test"
