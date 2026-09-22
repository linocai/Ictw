#!/bin/zsh
set -euo pipefail
test_dir=${0:A:h}
app_dir=${test_dir:h}
test_root=$(mktemp -d "${TMPDIR:-/tmp}/ictw-store-http.XXXXXX")
fixture_suite="com.lino.ictw.store-http.${test_root:t}"
fixture_pid=""
cleanup() {
  result=$?
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  defaults delete "$fixture_suite" >/dev/null 2>&1 || true
  [[ $result -eq 0 ]] || cat "$test_root/fixture.log"
  # Inventory the exact owned tree after both children exit, verify unchanged
  # content, then remove it. No application cache outside this root is touched.
  python3 - "$test_root" "$fixture_suite" <<'PY'
import hashlib, pathlib, plistlib, shutil, sys
root = pathlib.Path(sys.argv[1])
assert root.name.startswith('ictw-store-http.') and root.is_dir()
suite = sys.argv[2]
assert suite == 'com.lino.ictw.store-http.' + root.name
preferences = pathlib.Path.home() / 'Library/Preferences' / (suite + '.plist')
if preferences.exists():
    # CFPreferences may leave a 42-byte empty domain after defaults delete.
    # Remove only this invocation's verified empty footprint.
    assert plistlib.loads(preferences.read_bytes()) == {}
    preferences.unlink()
paths = sorted(root.rglob('*'))
assert not any(p.is_symlink() for p in paths)
manifest = {p: (p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest())
            for p in paths if p.is_file()}
assert all(p.stat().st_size == size and hashlib.sha256(p.read_bytes()).hexdigest() == digest
           for p, (size, digest) in manifest.items())
size = sum(item[0] for item in manifest.values())
shutil.rmtree(root)
print(f'Cleaned owned HTTP fixture: {len(manifest)} files, {size} bytes -> 0; no retained fixture data')
PY
}
trap cleanup EXIT
python3 "$test_dir/v211_http_fixture.py" --port-file "$test_root/port" > "$test_root/fixture.log" 2>&1 &
fixture_pid=$!
for attempt in {1..100}; do
  [[ -s "$test_root/port" ]] && break
  kill -0 "$fixture_pid" 2>/dev/null || { cat "$test_root/fixture.log"; exit 1; }
  sleep 0.02
done
[[ -s "$test_root/port" ]]
export LINOI_DEBUG_BASE_URL="http://127.0.0.1:$(cat "$test_root/port")"
export LINOI_DEBUG_TOKEN="synthetic-test-token"
export LINOI_DEBUG_DATA_ROOT="$test_root/data"
export LINOI_DEBUG_DEFAULTS_SUITE="$fixture_suite"
xcrun swiftc -swift-version 6 -D DEBUG -parse-as-library \
  "$app_dir/LinoI/LinoModels.swift" "$app_dir/LinoI/LinoAPI.swift" \
  "$app_dir/LinoI/ChapterDraftCache.swift" "$app_dir/LinoI/ClientSyncStore.swift" \
  "$app_dir/LinoI/InspirationCreator.swift" "$app_dir/LinoI/V2Shared/V2DeskPresentation.swift" \
  "$app_dir/LinoI/LinoTheme.swift" "$app_dir/LinoI/LinoErrorPresenter.swift" \
  "$app_dir/LinoI/NoticeBus.swift" "$app_dir/LinoI/LinoStores.swift" \
  "$test_dir/V211StoreHTTPTests.swift" -o "$test_root/tests"
python3 - "$test_root/tests" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run([sys.argv[1]], timeout=150).returncode)
except subprocess.TimeoutExpired:
    print('Store HTTP regressions exceeded the 150-second safety bound', flush=True)
    sys.exit(1)
PY
