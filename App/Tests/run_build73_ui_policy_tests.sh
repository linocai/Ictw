#!/bin/zsh
set -euo pipefail
source_dir=${0:A:h}
validation_root=${ICTW_UI_TEST_ROOT:-/tmp/ictw-build73/builder/ui73}
mkdir -p "$validation_root"
validation_run=$(mktemp -d "$validation_root/run.XXXXXX")
cleanup() {
  python3 - "$validation_run" "$validation_root" <<'PY'
import hashlib,pathlib,shutil,subprocess,sys
root,parent=map(pathlib.Path,sys.argv[1:])
assert root.parent.resolve()==parent.resolve() and root.name.startswith('run.') and not root.is_symlink()
paths=list(root.rglob('*'))
assert not any(p.is_symlink() for p in paths)
manifest={p:(p.stat().st_size,hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths if p.is_file()}
occupied=subprocess.run(['/usr/sbin/lsof','-t','+D',str(root)],capture_output=True,timeout=10)
assert occupied.returncode==1 and not occupied.stdout
assert all(p.stat().st_size==size and hashlib.sha256(p.read_bytes()).hexdigest()==digest for p,(size,digest) in manifest.items())
shutil.rmtree(root)
print(f'Cleaned owned Build73 UI artifacts: {sum(v[0] for v in manifest.values())} bytes -> 0')
PY
}
trap cleanup EXIT
python3 - "$source_dir" "$validation_run/interactions.swift" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); output=pathlib.Path(sys.argv[2])
source=(root/'../LinoI/V2IOS/V2IOSChapterDeskView.swift').read_text()
start=source.index('@MainActor\nfinal class V2IOSChapterActionCoordinator:')
opening=source.index('{',start); depth=1; end=opening+1
while depth:
    depth+=(source[end]=='{')-(source[end]=='}');end+=1
coordinator=source[start:end]
text=(root/'Build73IOSInteractionTests.swift').read_text().replace('// BUILD73:COORDINATOR',coordinator)
assert '// BUILD73:' not in text
output.write_text(text)
PY
xcrun swiftc -parse-as-library -swift-version 6 -module-cache-path "$validation_run/cache" \
  "$source_dir/../LinoI/LinoModels.swift" "$source_dir/../LinoI/LinoAPI.swift" \
  "$source_dir/../LinoI/LinoErrorPresenter.swift" "$source_dir/../LinoI/ChapterDraftCache.swift" \
  "$source_dir/../LinoI/V2Shared/V2DeskPresentation.swift" \
  "$validation_run/interactions.swift" -o "$validation_run/interactions"
"$validation_run/interactions"
