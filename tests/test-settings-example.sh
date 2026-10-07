#!/bin/bash
# Tests for examples/settings.json -- the wiring example readers copy.
#
# Every hook entry must carry an explicit numeric `timeout`. Without one the
# harness default applies, and a hook that runs past its timeout is treated as a
# non-blocking error: for a fail-closed guard that means the command is allowed.
# The guards must also get a longer bound than the advisory hooks. (#5)
#
# Run: bash tests/test-settings-example.sh

set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SETTINGS="${SETTINGS:-$ROOT/examples/settings.json}"
. "$ROOT/lib/resolve-python.sh"
PY="$(resolve_python || true)"
[ -n "$PY" ] || { echo "FATAL: no working Python 3"; exit 1; }

pass=0; fail=0
while IFS='|' read -r verdict name detail; do
  case "$verdict" in
    PASS) echo "  PASS  $name"; pass=$((pass+1)) ;;
    FAIL) echo "  FAIL  $name -- $detail"; fail=$((fail+1)) ;;
  esac
done < <(SETTINGS="$SETTINGS" "$PY" -X utf8 -c '
import json, os, re
d = json.load(open(os.environ["SETTINGS"], encoding="utf-8"))
entries = []
for event, groups in d.get("hooks", {}).items():
    for g in groups:
        for h in g.get("hooks", []):
            m = re.search(r"hooks/([\w-]+\.sh)", h.get("command", ""))
            entries.append((event, m.group(1) if m else h.get("command", ""), h.get("timeout")))
# Positive control: the walk found the wiring at all.
print(("PASS" if len(entries) >= 5 else "FAIL") + "|found the wired entries (%d)|expected at least 5" % len(entries))
for event, name, t in entries:
    ok = isinstance(t, int) and not isinstance(t, bool) and t > 0
    print(("PASS" if ok else "FAIL") + "|%s %s has a positive integer timeout|got %r" % (event, name, t))
guards = [t for e, n, t in entries if n in ("secrets-scan.sh", "skip-ci-guard.sh", "worktree-guard.sh")]
advisory = [t for e, n, t in entries if n in ("term-scan.sh", "session-registry.sh")]
if all(isinstance(x, int) for x in guards + advisory) and guards and advisory:
    ok = min(guards) > max(advisory)
    print(("PASS" if ok else "FAIL") + "|every guard bound exceeds every advisory bound|guards %r advisory %r" % (guards, advisory))
else:
    print("FAIL|every guard bound exceeds every advisory bound|missing or non-integer timeouts")
')

# Negative control: a copy with one timeout removed must be caught.
# (Skipped inside the child run, which would otherwise recurse.)
if [ -z "${SETTINGS_NEGCTL:-}" ]; then
TMPS="$(mktemp)"; trap 'rm -f "$TMPS"' EXIT
"$PY" -X utf8 -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["hooks"]["PreToolUse"][0]["hooks"][0].pop("timeout", None)
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
' "$SETTINGS" "$TMPS"
if SETTINGS_NEGCTL=1 SETTINGS="$TMPS" bash "$0" 2>/dev/null | grep -q "FAIL"; then
  echo "  PASS  a missing timeout is detected (negative control)"; pass=$((pass+1))
else
  echo "  FAIL  a missing timeout went undetected"; fail=$((fail+1))
fi
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
