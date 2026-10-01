#!/bin/zsh
set -euo pipefail
source_dir=${0:A:h}
validation_root=${ICTW_UI_TEST_ROOT:-/tmp/ictw-build70/ui}
mkdir -p "$validation_root"
validation_run=$(mktemp -d "$validation_root/run.XXXXXX")
print -r -- 'ictw-build70-ui-policy' > "$validation_run/.owner"
cleanup() {
  python3 - "$validation_run" "$validation_root" <<'PY'
import hashlib, pathlib, shutil, subprocess, sys
root, parent = map(pathlib.Path, sys.argv[1:])
assert root.is_dir() and not root.is_symlink() and root.name.startswith('run.')
assert root.parent.resolve() == parent.resolve()
assert (root / '.owner').read_text() == 'ictw-build70-ui-policy\n'
paths = sorted(root.rglob('*'))
assert not any(p.is_symlink() for p in paths)
manifest = {p: (p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths if p.is_file()}
occupied = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(root)], capture_output=True, timeout=10)
assert occupied.returncode == 1 and not occupied.stdout, 'UI test artifacts remain in use'
assert all(p.stat().st_size == size and hashlib.sha256(p.read_bytes()).hexdigest() == digest
           for p, (size, digest) in manifest.items())
size = sum(item[0] for item in manifest.values())
shutil.rmtree(root)
assert not root.exists()
print(f'Cleaned owned Build70 UI test: {len(manifest)} files, {size} bytes -> 0; no retained test data')
PY
}
trap cleanup EXIT

python3 - "$source_dir" "$validation_run/forms.swift" <<'PY'
import pathlib, sys
tests = pathlib.Path(sys.argv[1]); output = pathlib.Path(sys.argv[2])
mac = (tests / '../LinoIMac/V2/V2MacDeskSheets.swift').read_text()
ios = (tests / '../LinoI/V2IOS/V2IOSPeripheralViews.swift').read_text()
template = (tests / 'Build70FormLifecycleTests.swift').read_text()
def method(source, view, name):
    start = source.index('struct ' + view + ': View')
    start = source.index('private func ' + name + '(', start)
    opening = source.index('{', start)
    depth = 1; end = opening + 1
    while depth:
        assert end < len(source)
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func ', 'func ', 1)
for marker, source, view, name in [
    ('MAC_WORLD_SAVE', mac, 'V2MacWorldSheet', 'save'),
    ('IOS_WORLD_SAVE', ios, 'V2IOSWorldEditorView', 'saveAndDismiss'),
    ('MAC_PERSON_CREATE', mac, 'V2MacNewPersonSheet', 'create'),
    ('IOS_PERSON_CREATE', ios, 'V2IOSNewCharacterView', 'create'),
    ('IOS_PERSON_CONTEXT', ios, 'V2IOSNewCharacterView', 'ownsChapterContext'),
    ('IOS_PERSON_SAVE', ios, 'V2IOSCharacterDetailView', 'saveAndDismiss'),
]:
    template = template.replace('// BUILD70:' + marker, method(source, view, name))
assert '// BUILD70:' not in template
output.write_text(template)

def extract(source, needle):
    start = source.index(needle)
    opening = source.index('{', start)
    depth = 1; end = opening + 1
    while depth:
        assert end < len(source)
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
export_template = (tests / 'Build70ExportLifecycleTests.swift').read_text()
export_ios = (tests / '../LinoI/V2IOS/V2IOSSettingsAndExport.swift').read_text()
export_mac = (tests / '../LinoIMac/MacExportSaver.swift').read_text()
primitives = (tests / '../LinoI/V2IOS/V2IOSPrimitives.swift').read_text()
for marker, body in [
    ('MAC_PACKAGE', extract(export_mac, 'static func exportProject(')),
    ('MAC_PROSE', extract(export_mac, 'static func exportComposed(')),
    ('MAC_SAVE_FILES', extract(export_mac, 'private static func save(files:')),
    ('IOS_PACKAGE', method(export_ios, 'V2IOSProjectPackageSheet', 'exportCurrentBook')),
    ('IOS_PROSE', method(export_ios, 'V2IOSExportSheet', 'startExport')),
    ('IOS_CANCEL', method(export_ios, 'V2IOSExportSheet', 'cancelExport')),
    ('IOS_CURRENT', method(export_ios, 'V2IOSExportSheet', 'isCurrentExportSession')),
    ('IOS_FINISH', method(export_ios, 'V2IOSExportSheet', 'finishExport')),
    ('IOS_WRITE', extract(primitives, 'static func write(_ files:')),
]:
    export_template = export_template.replace('// BUILD70:' + marker, body)
assert '// BUILD70:' not in export_template
# Redirect the filesystem boundary to this owned fixture directory. All
# handler control flow and persistence/NoticeBus calls remain verbatim.
export_template = export_template.replace('FileManager.default.temporaryDirectory', 'fixtureOutputRoot()')
output.with_name('exports.swift').write_text(export_template)

recovery = (tests / '../LinoI/V2Shared/V2RetainedChapterDrafts.swift').read_text()
ios_root = (tests / '../LinoI/V2IOS/V2IOSRootView.swift').read_text()
mac_root = (tests / '../LinoIMac/V2/V2MacDeskRoot.swift').read_text()
recovery_template = (tests / 'Build70RetainedDraftLifecycleTests.swift').read_text()
for marker, view, name in [
    ('RETAINED_RELOAD', 'V2RetainedChapterDrafts', 'reload'),
    ('RETAINED_COPY', 'V2RetainedChapterDraftDetail', 'copy'),
    ('RETAINED_REQUEST', 'V2RetainedChapterDraftDetail', 'requestRemoval'),
    ('RETAINED_CANCEL', 'V2RetainedChapterDraftDetail', 'cancelRemoval'),
    ('RETAINED_CONFIRM', 'V2RetainedChapterDraftDetail', 'confirmRemoval'),
    ('RETAINED_REMOVE', 'V2RetainedChapterDraftDetail', 'removeCopy'),
]:
    recovery_template = recovery_template.replace('// BUILD70:' + marker, method(recovery, view, name))
for marker, source, view in [
    ('RETAINED_IOS_STATUS', ios_root, 'V2IOSSyncStatusBar'),
    ('RETAINED_MAC_STATUS', mac_root, 'V2MacSyncStatusButton'),
]:
    section = source[source.index('struct ' + view + ': View'):]
    section = section[:section.index('\nprivate struct ', 1)]
    assert 'else if sync.hasRetainedChapterDrafts' in section, 'Retained-only recovery shortcut must exist'
    shortcut = section.split('else if sync.hasRetainedChapterDrafts', 1)[1].split('private var state:', 1)[0]
    assert 'Button(action: openCenter)' in shortcut, 'Recovery shortcut must actually open the sync center'
    body = extract(section, 'private var state:').replace('private var ', 'var ', 1)
    recovery_template = recovery_template.replace('// BUILD70:' + marker, body)
assert '// BUILD70:' not in recovery_template
for source in [ios_root, mac_root]:
    assert 'V2RetainedChapterDrafts()' in source, 'Both sync centers must present recovery'
assert 'copy(draft.copyText)' in recovery and 'copy(draft.draftText)' in recovery
assert 'readOnlyField("本章 Bible", text: draft.userPrompt)' in recovery
assert 'readOnlyField("作者备注", text: draft.authorNote)' in recovery
output.with_name('recovery.swift').write_text(recovery_template)
PY

xcrun swiftc -swift-version 6 -module-cache-path "$validation_run/cache" \
  "$source_dir/../LinoI/LinoModels.swift" \
  "$source_dir/../LinoI/LinoAPI.swift" "$source_dir/../LinoI/LinoErrorPresenter.swift" \
  "$source_dir/../LinoIMac/V2/V2MacPersonaDraft.swift" \
  "$source_dir/../LinoIMac/V2/V2MacFormDrafts.swift" \
  "$source_dir/Build70UIPolicyTests.swift" -o "$validation_run/policies"
"$validation_run/policies"
xcrun swiftc -swift-version 6 -module-cache-path "$validation_run/cache" \
  "$source_dir/../LinoI/LinoModels.swift" "$source_dir/../LinoI/LinoAPI.swift" \
  "$source_dir/../LinoI/LinoErrorPresenter.swift" "$validation_run/forms.swift" -o "$validation_run/forms"
"$validation_run/forms"
xcrun swiftc -swift-version 6 -module-cache-path "$validation_run/cache" \
  "$source_dir/../LinoI/LinoModels.swift" "$source_dir/../LinoI/LinoAPI.swift" \
  "$source_dir/../LinoI/LinoErrorPresenter.swift" \
  "$source_dir/../LinoI/V2Shared/V2ExportDraftGuard.swift" \
  "$validation_run/exports.swift" -o "$validation_run/exports"
ICTW_EXPORT_FIXTURE_ROOT="$validation_run/export-files" "$validation_run/exports"
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$validation_run/cache" \
  "$validation_run/recovery.swift" -o "$validation_run/recovery"
"$validation_run/recovery"
