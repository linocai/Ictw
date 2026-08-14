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

# v2 may surface the current manuscript only. Writer-side alternatives remain
# backend audit records. Reject author-facing candidate/adopt/discard text and
# explicit Writer candidate-flow types, while allowing the unrelated internal
# inspiration `recordAdoption` undo mechanism.
v2_dirs=("$app_dir/LinoI/V2Shared" "$app_dir/LinoI/V2IOS" "$app_dir/LinoIMac/V2")
if rg -n -i '"[^"]*(候选|采用|丢弃|candidate|adopt|discard)[^"]*"' "${v2_dirs[@]}"; then
  print -u2 "V2 author-facing code must not expose candidate/adopt/discard copy"
  exit 1
fi
if rg -n 'WriterCandidate|AdoptCandidate|DiscardCandidate|writerCandidate|adoptCandidate|discardCandidate' "${v2_dirs[@]}"; then
  print -u2 "V2 author-facing code must not expose a Writer candidate flow"
  exit 1
fi

# Reading an existing next chapter and creating a brand-new chapter are
# separate actions in v2.0.1. Keep the removed ambiguous wording and symbol
# from returning anywhere in the v2 author surfaces.
if rg -n '开始下一章|startNextChapter' "${v2_dirs[@]}"; then
  print -u2 "V2 must distinguish next-chapter reading from starting a new chapter"
  exit 1
fi

# Regression gates for v2 interaction wiring that pure presentation tests
# cannot exercise: banner actions must dispatch themselves, and iOS chapter
# transitions must clear chapter-scoped inspiration state before loading.
rg -Fq 'Button(action.title) { perform(action) }' "$app_dir/LinoIMac/V2/V2MacDeskEditor.swift"
rg -Fq 'inspiration.clearIfChapterChanged(to: summary.id)' "$app_dir/LinoI/V2IOS/V2IOSChapterDeskView.swift"
chapter_edit_guard_count=$(rg -Fc 'guard ChapterEditingPolicy.canEdit(chapter) else { return }' "$app_dir/LinoI/LinoStores.swift")
if (( chapter_edit_guard_count < 2 )); then
  print -u2 "Finalized chapter edits must be blocked for prose fields and character links"
  exit 1
fi

xcrun swiftc -parse-as-library \
  "$app_dir/LinoI/LinoModels.swift" \
  "$app_dir/LinoI/LinoAPI.swift" \
  "$app_dir/LinoI/ChapterDraftCache.swift" \
  "$app_dir/LinoI/InspirationCreator.swift" \
  "$app_dir/LinoI/V2Shared/V2DeskPresentation.swift" \
  "$app_dir/LinoI/LinoTheme.swift" \
  "$app_dir/LinoI/LinoErrorPresenter.swift" \
  "$app_dir/LinoI/NoticeBus.swift" \
  "$test_dir/V202NoticeLifecycleTests.swift" \
  "$test_dir/ClientStateTests.swift" \
  -o "$test_binary"

"$test_binary"
