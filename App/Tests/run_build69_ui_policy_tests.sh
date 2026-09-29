#!/bin/zsh
set -euo pipefail

source_dir=${0:A:h}
validation_root=${ICTW_UI_TEST_ROOT:-${TMPDIR:-/tmp}/ictw-build69-ui}
created_root=false
[[ -d "$validation_root" ]] || created_root=true
mkdir -p "$validation_root"
validation_run=$(mktemp -d "$validation_root/run.XXXXXX")
print -r -- 'ictw-build69-ui-policy' > "$validation_run/.owner"
cleanup() {
  python3 - "$validation_run" "$validation_root" "$created_root" <<'PY'
import hashlib, pathlib, shutil, subprocess, sys
root = pathlib.Path(sys.argv[1])
parent = pathlib.Path(sys.argv[2])
assert root.is_dir() and not root.is_symlink() and root.name.startswith('run.')
assert root.parent.resolve() == parent.resolve()
assert (root / '.owner').read_text() == 'ictw-build69-ui-policy\n'
paths = sorted(root.rglob('*'))
assert not any(p.is_symlink() for p in paths)
manifest = {p: (p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest())
            for p in paths if p.is_file()}
occupied = subprocess.run(['/usr/sbin/lsof', '-t', '+D', str(root)],
                          capture_output=True, timeout=10)
assert occupied.returncode == 1 and not occupied.stdout, 'UI test artifacts remain in use'
assert all(p.stat().st_size == size and hashlib.sha256(p.read_bytes()).hexdigest() == digest
           for p, (size, digest) in manifest.items())
size = sum(item[0] for item in manifest.values())
shutil.rmtree(root)
assert not root.exists()
if sys.argv[3] == 'true' and not any(parent.iterdir()):
    parent.rmdir()
print(f'Cleaned owned UI policy test: {len(manifest)} files, {size} bytes -> 0; no retained test data')
PY
}
trap cleanup EXIT

xcrun swiftc \
  -module-cache-path "$validation_run/cache" \
  "$source_dir/../LinoIMac/V2/V2MacPersonaDraft.swift" \
  "$source_dir/../LinoI/V2Shared/V2ChapterDeletionNavigation.swift" \
  "$source_dir/Build69UIPolicyTests.swift" \
  -o "$validation_run/tests"
"$validation_run/tests" "$@"
