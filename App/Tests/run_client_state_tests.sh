#!/bin/zsh
set -euo pipefail

test_dir=${0:A:h}
app_dir=${test_dir:h}
test_binary=$(mktemp "${TMPDIR:-/tmp}/ictw-client-state-tests.XXXXXX")
trap 'rm -f "$test_binary"' EXIT

# These source guards used to run through ripgrep inside `if rg ...; then`.
# `set -e` exempts `if` conditions, so on a machine without ripgrep every one
# of them scored "no violation found" and the gate passed while checking
# nothing. grep ships with macOS and reports 0 match / 1 no-match / >=2 error,
# so tool failure is now distinguishable from a clean result.
#
# forbid <message> <grep-args...>   fails when the pattern IS present.
# require <message> <grep-args...>  fails when the pattern is ABSENT.
forbid() {
  local message=$1
  shift
  local rc=0
  grep "$@" >/dev/null 2>&1 || rc=$?
  if ((rc == 0)); then
    print -u2 "$message"
    exit 1
  fi
  if ((rc > 1)); then
    print -u2 "gate could not run (grep exit $rc): $message"
    exit 1
  fi
}

require() {
  local message=$1
  shift
  local rc=0
  grep "$@" >/dev/null 2>&1 || rc=$?
  if ((rc != 0)); then
    print -u2 "$message"
    exit 1
  fi
}

swift_only=(-r --include='*.swift')

# Presenting the inspiration UI is intentionally passive. Keep the explicit
# start button on both platforms and reject the old open-to-generate shortcut.
forbid "Inspiration UI must not generate on open" \
  "${swift_only[@]}" -E 'inspiration\.activate\(|func activate\(' "$app_dir"

# Multi-line shapes need perl; grep has no portable -U equivalent.
for guard_file in "$app_dir/LinoI/V2IOS/V2IOSChapterDeskView.swift" "$app_dir/LinoIMac/V2/V2MacDeskRoot.swift"; do
  if [[ ! -f $guard_file ]]; then
    print -u2 "gate could not run: missing $guard_file"
    exit 1
  fi
done
if perl -0777 -ne 'exit(/Button\s*\{\s*guard editor\.currentChapter/ ? 0 : 1)' \
    "$app_dir/LinoI/V2IOS/V2IOSChapterDeskView.swift" \
  || perl -0777 -ne 'exit(/private func openInspiration\(\)\s*\{\s*guard/ ? 0 : 1)' \
    "$app_dir/LinoIMac/V2/V2MacDeskRoot.swift"; then
  print -u2 "Inspiration entry must never fail silently while a chapter is loading"
  exit 1
fi

# The explicit start button must exist on the surfaces that actually ship.
# The previous revision of this gate pointed at LinoI/ChapterEditorViews.swift,
# which the v2 app no longer constructs, so it asserted nothing about the
# shipping sheets.
require "iOS inspiration sheet must keep an explicit start button" \
  -F '"开始找灵感"' "$app_dir/LinoI/V2IOS/V2IOSPeripheralViews.swift"
require "macOS inspiration sheet must keep an explicit start button" \
  -F '"开始找灵感"' "$app_dir/LinoIMac/V2/V2MacDeskSheets.swift"

# v2 may surface the current manuscript only. Writer-side alternatives remain
# backend audit records. Reject author-facing candidate/adopt/discard text and
# explicit Writer candidate-flow types, while allowing the unrelated internal
# inspiration `recordAdoption` undo mechanism.
v2_dirs=("$app_dir/LinoI/V2Shared" "$app_dir/LinoI/V2IOS" "$app_dir/LinoIMac/V2")
# v2.1 has an explicit *server/local conflict* decision. “采用服务器版本” is
# therefore legitimate recovery copy, unlike the retired Writer-candidate
# adoption flow. Keep the guard narrowly focused on candidate wording.
forbid "V2 author-facing code must not expose Writer candidate copy" \
  "${swift_only[@]}" -iE '"[^"]*(候选|candidate)[^"]*"' "${v2_dirs[@]}"
forbid "V2 author-facing code must not expose a Writer candidate flow" \
  "${swift_only[@]}" -E 'WriterCandidate|AdoptCandidate|DiscardCandidate|writerCandidate|adoptCandidate|discardCandidate' "${v2_dirs[@]}"

# Reading an existing next chapter and creating a brand-new chapter are
# separate actions in v2.0.1. Keep the removed ambiguous wording and symbol
# from returning anywhere in the v2 author surfaces.
forbid "V2 must distinguish next-chapter reading from starting a new chapter" \
  "${swift_only[@]}" -E '开始下一章|startNextChapter' "${v2_dirs[@]}"

# Regression gates for v2 interaction wiring that pure presentation tests
# cannot exercise: banner actions must dispatch themselves, and iOS chapter
# transitions must clear chapter-scoped inspiration state before loading.
require "macOS banner actions must dispatch themselves" \
  -F 'Button(action.title) { perform(action) }' "$app_dir/LinoIMac/V2/V2MacDeskEditor.swift"
require "iOS chapter transitions must clear chapter-scoped inspiration state" \
  -F 'inspiration.clearIfChapterChanged(to: summary.id)' "$app_dir/LinoI/V2IOS/V2IOSChapterDeskView.swift"

chapter_edit_guard_count=$(grep -cF 'guard ChapterEditingPolicy.canEdit(chapter) else { return }' "$app_dir/LinoI/LinoStores.swift")
if (( chapter_edit_guard_count < 2 )); then
  print -u2 "Finalized chapter edits must be blocked for prose fields and character links"
  exit 1
fi

# Binding a model must not restate thinking/effort/temperature: the server
# reads an explicitly encoded null as "clear this field", so a profile-only
# patch needs its own payload type.
require "Profile binding must send only llm_profile_id" \
  -F 'AgentBindingProfilePayload(llmProfileId: profileId)' "$app_dir/LinoI/LinoStores.swift"

# Profile PATCH bodies can contain a newly entered API key, but the offline
# pending/conflict cache is durable and author-visible. Keep the redacted
# payload boundary mechanically pinned so a later refactor cannot serialize a
# credential along with a conflict record.
require "Profile conflicts must use the redacted payload" \
  -F 'LLMProfileConflictPayload(profile: profile)' "$app_dir/LinoI/LinoStores.swift"
forbid "Sync cache must never contain API-key fields" \
  -iE 'api[_-]?key' "$app_dir/LinoI/ClientSyncStore.swift"
require "Book override creation must explicitly opt into If-Match zero" \
  -F 'allowZeroRevision: revision == nil' "$app_dir/LinoI/LinoStores.swift"

# NoticeBus is the only channel that tells the author a save failed. A single
# overlay on the app root is invisible inside pushed destinations and sheets.
require "iOS notice overlay must exist as a reusable modifier" \
  -F 'func v2IOSNoticeOverlay()' "$app_dir/LinoI/V2IOS/V2IOSRootView.swift"
for notice_host in \
  "$app_dir/LinoI/V2IOS/V2IOSRootView.swift" \
  "$app_dir/LinoI/V2IOS/V2IOSPeripheralViews.swift" \
  "$app_dir/LinoI/V2IOS/V2IOSSettingsAndExport.swift"; do
  require "Every iOS presentation context that can save must carry the notice overlay: $notice_host" \
    -F '.v2IOSNoticeOverlay()' "$notice_host"
done

# A notice inset hosted outside the book-settings NavigationStack occupies the
# same top strip as its trailing Done button. The close target can then dismiss
# both the notice and the sheet. Pin the modifier to the List content, where
# SwiftUI starts the inset below the navigation bar.
if ! perl -0777 -ne 'exit(/\.v2IOSNoticeOverlay\(\)\s*\.navigationTitle\("书设置"\)/s ? 0 : 1)' \
    "$app_dir/LinoI/V2IOS/V2IOSSettingsAndExport.swift"; then
  print -u2 "Book-settings notices must stay below the navigation bar"
  exit 1
fi

# Rewrite and delete were both absent from the entire v2 UI until v2.0.4: the
# store methods and the backend endpoints existed the whole time and simply had
# no caller. That is a failure mode no compiler catches, so the entry points are
# pinned here.
require "Shared layer must expose the chapter command availability" \
  -F 'commands: V2DeskChapterCommands' "$app_dir/LinoI/V2Shared/V2DeskPresentation.swift"
for command_host in \
  "$app_dir/LinoIMac/V2/V2MacDeskEditor.swift" \
  "$app_dir/LinoI/V2IOS/V2IOSChapterDeskView.swift"; do
  require "Rewrite entry must stay wired on both platforms: $command_host" \
    -F 'commands.canRewrite' "$command_host"
  require "Delete entry must stay wired on both platforms: $command_host" \
    -F 'commands.canDelete' "$command_host"
  # Reading the availability flag only proves the symbol is referenced. The
  # way these two commands vanished the first time was a present-and-correct
  # `if` around a button that no longer existed, so pin the labels too.
  require "Rewrite must stay a visible, labelled control: $command_host" \
    -F '"重写本章"' "$command_host"
  require "Delete must stay a visible, labelled control: $command_host" \
    -F '"删除这一章"' "$command_host"
done

# Confirmation copy for a destructive action is a cross-platform contract, and
# the message is the only place the cascade impact is disclosed. A platform
# that hand-writes its own sentence escapes the copy tests entirely — which is
# how the reopen dialogs drifted apart before v2.0.4.
for confirmation_host in \
  "$app_dir/LinoIMac/V2/V2MacDeskRoot.swift" \
  "$app_dir/LinoI/V2IOS/V2IOSChapterDeskView.swift"; do
  require "Rewrite confirmation copy must come from the shared layer: $confirmation_host" \
    -F 'V2DeskRewriteConfirmation.message(' "$confirmation_host"
  require "Reopen confirmation copy must come from the shared layer: $confirmation_host" \
    -F 'V2DeskReopenConfirmation.message(' "$confirmation_host"
  # A labelled button wired to nothing looks identical in a screenshot and in
  # a grep for the label. These are the two store calls that make the entries
  # real.
  require "Rewrite entry must actually reach the store: $confirmation_host" \
    -F 'editor.rewrite()' "$confirmation_host"
  require "Delete entry must actually reach the store: $confirmation_host" \
    -F 'editor.deleteCurrentChapter()' "$confirmation_host"
done

# Both platforms must compute the chapter's position themselves. The initialiser
# deliberately has no default, but a future call site could still hard-code
# `false` and quietly withhold delete forever.
for position_host in \
  "$app_dir/LinoIMac/V2/V2MacDeskRoot.swift" \
  "$app_dir/LinoI/V2IOS/V2IOSChapterDeskView.swift"; do
  require "Last-chapter state must come from the shared helper: $position_host" \
    -F 'V2DeskChapterPosition.isLastChapter' "$position_host"
done
# Whitespace-tolerant: a default written as `Bool=false` is the same defect
# and must not slip past on formatting alone.
forbid "V2DeskEditorSource.isLastChapterInBook must not regain a default" \
  -E 'isLastChapterInBook:[[:space:]]*Bool[[:space:]]*=' "$app_dir/LinoI/V2Shared/V2DeskPresentation.swift"

# Narrow by construction: this rejects exactly one literal shape, the client
# blanking the draft through `editString`. Hard rule 35's real enforcement
# point is server-side promotion timing (new prose replaces the old only after
# the deterministic checks and Checker both pass); this guard only stops the
# client from pre-emptying the body it is supposed to keep showing.
forbid "Rewrite must not clear the draft through editString" \
  -rE 'editString\(\\\.draftText, value: ""\)' "$app_dir/LinoI" "$app_dir/LinoIMac"

# The preview is a network round trip and the user can leave during it. Both
# platforms must re-check chapter identity before raising the dialog.
for race_host in \
  "$app_dir/LinoIMac/V2/V2MacDeskRoot.swift" \
  "$app_dir/LinoI/V2IOS/V2IOSChapterDeskView.swift"; do
  require "Rewrite preview must re-check chapter identity after awaiting: $race_host" \
    -F 'editor.currentChapter?.id == chapterID' "$race_host"
done

xcrun swiftc -parse-as-library \
  "$app_dir/LinoI/LinoModels.swift" \
  "$app_dir/LinoI/LinoAPI.swift" \
  "$app_dir/LinoI/ChapterDraftCache.swift" \
  "$app_dir/LinoI/ClientSyncStore.swift" \
  "$app_dir/LinoI/InspirationCreator.swift" \
  "$app_dir/LinoI/V2Shared/V2DeskPresentation.swift" \
  "$app_dir/LinoI/LinoTheme.swift" \
  "$app_dir/LinoI/LinoErrorPresenter.swift" \
  "$app_dir/LinoI/NoticeBus.swift" \
  "$test_dir/V202NoticeLifecycleTests.swift" \
  "$test_dir/ClientStateTests.swift" \
  -o "$test_binary"

"$test_binary"
