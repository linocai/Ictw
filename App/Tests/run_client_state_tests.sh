#!/bin/zsh
set -euo pipefail

test_dir=${0:A:h}
app_dir=${test_dir:h}
test_binary=$(mktemp "${TMPDIR:-/tmp}/ictw-client-state-tests.XXXXXX")
trap 'rm -f "$test_binary"' EXIT

xcrun swiftc -parse-as-library \
  "$app_dir/LinoI/LinoModels.swift" \
  "$app_dir/LinoI/LinoAPI.swift" \
  "$app_dir/LinoI/InspirationCreator.swift" \
  "$test_dir/ClientStateTests.swift" \
  -o "$test_binary"

"$test_binary"
