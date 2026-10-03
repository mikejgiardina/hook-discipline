#!/bin/bash
# Tests for the stdin-payload fallback when `timeout` is not GNU coreutils.
#
# === The defect ===
# The hooks read their payload with `timeout 2 cat`. When the `timeout` first on
# PATH is not GNU's (Windows' System32 timeout.exe prints "Invalid syntax" and
# exits 1), it never reads stdin. The old `|| echo ""` turned that into an EMPTY
# payload, and every guard then saw no command and no path, and allowed. That is
# silent and layer-wide, and it reads exactly like "nothing to object to".
#
# === Axes ===
#   S  STATIC    every `timeout N cat` read carries the fallback. This is the
#                coverage control: B proves the shape works, S proves every site
#                has the shape.
#   B  BEHAVIOR  with a fake non-GNU `timeout` first on PATH, the shared payload
#                reader still returns the payload. Paired with the real timeout.
#
# Run: bash tests/test-timeout-fallback.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/fixture-root.sh"
fixture_root_init timeoutfallback

pass=0; fail=0; skip=0
check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  PASS %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL %s — expected [%s], got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
}

echo "test-timeout-fallback.sh"
check "0  fixture root scope" "outside" "$(fixture_root_scope "$ROOT" "$FIX")"

# --- S. static coverage ---------------------------------------------------------
uncovered() { # <file...> -> one line per read site WITHOUT the fallback
  grep -n -E 'timeout[[:space:]]+[0-9.]+[[:space:]]+cat' "$@" 2>/dev/null \
    | grep -v -E '_trc=\$\?; \[ "\$_trc" -eq 124 \]' \
    | grep -v -E ':[0-9]+:[[:space:]]*#'
}
FILES=$(ls "$ROOT"/hooks/*.sh "$ROOT"/lib/*.sh)
n_sites=$(grep -l -E 'timeout[[:space:]]+[0-9.]+[[:space:]]+cat' $FILES | wc -l | tr -d ' ')
check "S1 the enumeration finds read sites (an empty scan would be vacuous)" "YES" \
      "$([ "$n_sites" -ge 5 ] && echo YES || echo "NO ($n_sites)")"
check "S2 every read site carries the fallback" "" "$(uncovered $FILES)"
printf '#!/usr/bin/env bash\nPAYLOAD=$(timeout 2 cat 2>/dev/null || echo "")\n' > "$FIX/unconverted.sh"
check "S3 CONTROL the same detector flags an unconverted read" "YES" \
      "$([ -n "$(uncovered "$FIX/unconverted.sh")" ] && echo YES || echo NO)"

# --- B. behavior under a non-GNU timeout ------------------------------------------
FT="$FIX/fake_timeout"; mkdir -p "$FT"
printf '#!/usr/bin/env bash\necho "Invalid syntax" >&2\nexit 1\n' > "$FT/timeout"
chmod +x "$FT/timeout"
P='{"tool_name":"Bash","tool_input":{"command":"git commit -m x"}}'
probe='. "$1/lib/payload.sh"; printf "%s" "$(hook_payload)"'
check "B1 fake timeout: hook_payload still returns the payload" "$P" \
      "$(printf '%s' "$P" | PATH="$FT:$PATH" CLAUDE_TOOL_INPUT= bash -c "$probe" _ "$ROOT" 2>/dev/null)"
check "B2 CONTROL real timeout: hook_payload returns the same payload" "$P" \
      "$(printf '%s' "$P" | CLAUDE_TOOL_INPUT= bash -c "$probe" _ "$ROOT" 2>/dev/null)"

echo
printf 'passed: %d  failed: %d  skipped: %d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
exit 0
