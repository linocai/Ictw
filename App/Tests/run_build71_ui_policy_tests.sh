#!/bin/zsh
set -euo pipefail
source_dir=${0:A:h}
validation_root=${ICTW_UI_TEST_ROOT:-/tmp/ictw-build71/ui71}
mkdir -p "$validation_root"
validation_run=$(mktemp -d "$validation_root/run.XXXXXX")
cleanup() {
  python3 - "$validation_run" "$validation_root" <<'PY_CLEAN'
import hashlib,pathlib,subprocess,sys
root,parent=map(pathlib.Path,sys.argv[1:])
assert root.parent.resolve()==parent.resolve() and root.name.startswith('run.') and not root.is_symlink()
paths=list(root.iterdir())
assert all(p.name in {'forms','forms.swift'} and p.is_file() and not p.is_symlink() for p in paths)
manifest={p:(p.stat().st_size,hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths}
occupied=subprocess.run(['/usr/sbin/lsof','-t','+D',str(root)],capture_output=True,timeout=10)
assert occupied.returncode==1 and not occupied.stdout
for p,(size,digest) in manifest.items():
    assert p.stat().st_size==size and hashlib.sha256(p.read_bytes()).hexdigest()==digest
    p.unlink()
root.rmdir()
print(f'Cleaned owned Build71 UI artifacts: {sum(v[0] for v in manifest.values())} bytes -> 0')
PY_CLEAN
}
trap cleanup EXIT
python3 - "$source_dir" "$validation_run/forms.swift" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2])
def block(s,start):
    opening=s.index('{',start); depth=1; end=opening+1
    while depth:
        depth+=(s[end]=='{')-(s[end]=='}'); end+=1
    return s[start:end]
def member(s,needle): return block(s,s.index(needle)).replace('private ', '',1)
mac=(root/'../LinoIMac/V2/V2MacDeskRoot.swift').read_text()
ios=(root/'../LinoI/V2IOS/V2IOSSettingsAndExport.swift').read_text()
model=ios[ios.index('private struct V2IOSBookModelEditor: View'):ios.index('private struct V2IOSProfileEditor: View')]
peripheral=(root/'../LinoI/V2IOS/V2IOSPeripheralViews.swift').read_text()
book=(root/'../LinoI/V2IOS/V2IOSBookshelfView.swift').read_text()
book=book[book.index('private struct V2IOSNewBookSheet: View'):]
shortcuts=[]
for flag, label in [('showNewBook','newBook'),('showSettings','settings')]:
    offset=0
    for scope in ['Shelf','Desk']:
        start=mac.index('.onChange(of: commandBus.'+flag+')',offset)
        body=block(mac,start).split('{ _, requested in',1)[1]
        shortcuts.append('func '+label+scope+'(_ requested: Bool) {'+body)
        offset=start+1
newbook=block(book,book.index('V2IOSPrimaryButton(title: creating'))
newbook='func create() {'+newbook.split(' {',1)[1]
assert 'TextField("书名", text: $title)\n                    .disabled(creating)' in book
assert 'TextEditor(text: $world)\n                    .disabled(creating)' in book
assert '.interactiveDismissDisabled(leaveCoordinator.blocksDismissal)' in ios
assert '.navigationBarBackButtonHidden(isDirty || saving)' in model
assert 'guard !initialized else { return }' in model
assert '.onChange(of: isDirty)' in model and '.onChange(of: saving)' in model
assert 'Button("返回", action: requestDismiss)' in model and 'Button("完成", action: requestDismiss)' in model
text=(root/'Build71FormLifecycleTests.swift').read_text()
for key,value in {
 'COORDINATOR': '@MainActor\n'+member(peripheral,'final class V2IOSCharacterSheetLeaveCoordinator:'),
 'SHORTCUTS':'\n'.join(shortcuts),
 'MODEL_METHODS':'\n'.join(member(model,needle) for needle in ['private var isDirty:', 'private func requestDismiss(', 'private func syncSheetLeaveCoordinator(', 'private func save(', 'private func load(', 'private func recoverLoadedDraft(']),
 'NEW_BOOK':newbook,
}.items(): text=text.replace('// BUILD71:'+key,value)
assert '// BUILD71:' not in text
out.write_text(text)
PY
xcrun swiftc -parse-as-library -swift-version 6 "$validation_run/forms.swift" -o "$validation_run/forms"
"$validation_run/forms"
