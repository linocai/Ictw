#!/bin/zsh
set -euo pipefail

test_dir=${0:A:h}
app_dir=${test_dir:h}
test_binary=$(mktemp "${TMPDIR:-/tmp}/ictw-client-state-tests.XXXXXX")
trap 'rm -f "$test_binary"' EXIT

# Presenting the inspiration UI is intentionally passive. Keep the explicit
# start button on both platforms and reject the old open-to-generate shortcut.
if rg -q 'inspiration\.activate\(|func activate\(' "$app_dir"; then
  print -u2 "Inspiration UI must not generate on open"
  exit 1
fi
if rg -U -q 'Button[[:space:]]*\{[[:space:]]*guard editor\.currentChapter' "$app_dir/LinoI/ChapterEditorViews.swift" \
  || rg -U -q 'private func openInspiration\(\)[[:space:]]*\{[[:space:]]*guard' "$app_dir/LinoIMac/MacWorkspaceView.swift"; then
  print -u2 "Inspiration entry must never fail silently while a chapter is loading"
  exit 1
fi
rg -q 'Button\("开始找灵感"' "$app_dir/LinoI/ChapterEditorViews.swift"
rg -q 'Button\("开始找灵感"' "$app_dir/LinoIMac/MacInspirationTab.swift"

xcrun swiftc -parse-as-library \
  "$app_dir/LinoI/LinoModels.swift" \
  "$app_dir/LinoI/LinoAPI.swift" \
  "$app_dir/LinoI/InspirationCreator.swift" \
  "$test_dir/ClientStateTests.swift" \
  -o "$test_binary"

"$test_binary"
