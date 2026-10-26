#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
policy_dir="$repo_dir/Glacier/Classes/Controllers/ICEInterfacePolicy"
xcrun clang -Wall -Wextra -Werror -I "$policy_dir" "$policy_dir/GlacierICEInterfaceFilter.c" "$repo_dir/Scripts/ICEInterfacePolicyTests/filter_tests.c" -o "$test_dir/filter-tests"
"$test_dir/filter-tests"
