#!/usr/bin/env bash
# Verify layout, package API compatibility, compiler dependency rules and private module boundaries.
set -euo pipefail
cd "$(dirname "$0")/.."
ORIN="${ORIN:-orin}"
python3 - <<'PY'
from pathlib import Path
import re
src = Path('src')
flat = sorted(str(p) for p in src.glob('*.or') if p.name != 'module.or')
if flat:
    raise SystemExit('Implementation files must live inside a module: ' + ', '.join(flat))
for directory in sorted(p for p in src.iterdir() if p.is_dir()):
    if not (directory / 'module.or').is_file():
        raise SystemExit(str(directory) + ' needs an explicit module.or interface')
source = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/', '', (src / 'module.or').read_text())
exports = set()
for block in re.findall(r'export\s*\{([^}]+)\}\s*from\s*"[^"]+"\s*;', source):
    exports.update(part.strip().split(' as ')[-1].strip() for part in block.split(',') if part.strip())
expected = set(Path('api/public-names.txt').read_text().splitlines())
if exports != expected:
    raise SystemExit('Package API changed. Removed: ' + str(sorted(expected - exports)) + '; added: ' + str(sorted(exports - expected)))
if re.sub(r'export\s*\{[^}]+\}\s*from\s*"[^"]+"\s*;', '', source).strip():
    raise SystemExit('src/module.or must contain only explicit re-exports')
print('Module layout and existing package exports: OK')
PY
"$ORIN" check --deps
probe_dir=$(mktemp -d src/.module-probe.XXXXXX)
probe="$probe_dir/main.or"
policy_dir=
output=$(mktemp)
cleanup() {
    rm -f "$probe" "$output"
    rmdir "$probe_dir"
    if [ -n "$policy_dir" ]; then rm -f "$policy_dir/main.or"; rmdir "$policy_dir"; fi
}
trap cleanup EXIT
while read -r private symbol; do
    [ -n "$private" ] || continue
    printf 'import { %s } from "../%s";\n' "$symbol" "$private" > "$probe"
    if "$ORIN" check "$probe" >"$output" 2>&1; then
        echo "FAIL: private implementation $private can be imported from outside its module" >&2
        exit 1
    fi
    if ! grep -q 'E0302' "$output"; then
        cat "$output" >&2
        echo "FAIL: expected E0302 for $private" >&2
        exit 1
    fi
    echo "Private module boundary: $private rejected (E0302)"
done < tools/module-boundaries.txt
# A module must also reject dependencies outside its declared policy, even through a public facade.
while read -r source target symbol; do
    policy_dir=$(mktemp -d "src/$source/.policy-probe.XXXXXX")
    printf 'import { %s } from "../../%s";\n' "$symbol" "$target" > "$policy_dir/main.or"
    if "$ORIN" check "$policy_dir/main.or" >"$output" 2>&1; then
        echo "FAIL: forbidden dependency $source -> $target was accepted" >&2
        exit 1
    fi
    if ! grep -q 'E0501' "$output"; then cat "$output" >&2; exit 1; fi
    echo "Dependency policy: $source -> $target rejected (E0501)"
    rm "$policy_dir/main.or"
    rmdir "$policy_dir"
    policy_dir=
done < tools/module-policies.txt
