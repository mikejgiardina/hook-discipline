#!/usr/bin/env bash
# Behavioural tests for hooks/term-scan.sh.
#
# === The structure that matters here ===
# term-scan produces NO OUTPUT in the common case. That is a deliberate design
# choice — a scanner that prints on every write gets ignored — and it is also
# what makes this hook uniquely easy to break without noticing. Every possible
# failure produces the same observable result as every success: silence.
#
# So no case in this file asserts silence on its own. Each quiet case is paired
# with a control that makes the SAME wiring produce output, usually by changing
# exactly one variable. If the hook were replaced tomorrow with `exit 0`, the
# quiet cases would all still pass and every control would go red.
#
# Cases 3/3N are the sharpest instance: 3 asserts that an internal path stays
# quiet even though its content is full of registry terms. On its own, that
# assertion is satisfied by a hook that cannot read files, cannot parse payloads,
# or was never invoked. 3N holds the content constant and moves only the
# directory, so the pair together says "silent BECAUSE excluded" rather than
# "silent for some reason".
#
# Hermetic: no network, no external CLI, no real registry.
# Run: bash tests/test-term-scan.sh

set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$ROOT/hooks/term-scan.sh"
[ -f "$HOOK" ] || { echo "FATAL: $HOOK not found"; exit 1; }

. "$TESTS_DIR/lib/fixture-root.sh"
fixture_root_init termscan

REG="$ROOT/examples/terms.example.json"
[ -f "$REG" ] || { echo "FATAL: example registry not found at $REG"; exit 1; }

# An ambient HOOK_PYTHON pin is honoured by resolve_python BEFORE any PATH
# lookup, which silently defeats both the python-free-PATH cases below and any
# interposed interpreter. Unset so this suite measures what it claims to.
unset HOOK_PYTHON

pass=0; fail=0; skip=0

# PRECONDITION_HOOK_PYTHON — enforcement, not a request.
# The `unset` above is a line a future edit can quietly drop, and nothing would
# fail if it did; every interposition below would silently measure the pin
# instead of its subject, and still pass. A comment asking for it is a request.
# This is the assertion.
if [ -z "${HOOK_PYTHON:-}" ]; then
  echo "  PASS  precondition: HOOK_PYTHON unset (a pin would outrank PATH)"; pass=$((pass+1))
else
  echo "  FAIL  precondition: HOOK_PYTHON is set ([${HOOK_PYTHON}]) — the pin outranks"
  echo "        PATH, so interposed interpreters below are not what is measured"; fail=$((fail+1))
fi


# Build a payload the way Claude Code delivers one: JSON on stdin, path nested
# under tool_input. Backslashes are doubled by the real serialiser; the helper
# under test unescapes them, so tests feed the forward-slash form.
payload() { printf '{"tool_input":{"file_path":"%s"}}' "$1"; }

run_hook() { # <file_path> [registry_override]
  local f="$1" reg="${2:-$REG}"
  payload "$f" | HOOK_TERM_REGISTRY="$reg" bash "$HOOK" 2>/dev/null
}

# WARN / QUIET rather than exit codes: this hook always exits 0 by design, so
# the exit code carries no information and asserting on it would be vacuous.
verdict() {
  if printf '%s' "$1" | grep -q 'TERM-SCAN WARNING'; then
    printf 'WARN'
  else
    printf 'QUIET'
  fi
}

check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  PASS %s (%s)\n' "$1" "$3"
    pass=$((pass+1))
  else
    printf '  FAIL %s — expected %s, got %s\n' "$1" "$2" "$3"
    fail=$((fail+1))
  fi
}

mk() { # <path> <content>
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

CANON="This document describes Project Vanadium in detail."
ALIAS="This document describes the Vanadium initiative in detail."
CLEAN="This document describes nothing sensitive whatsoever."

echo "test-term-scan.sh"

# --- 0. fixture root is outside any checkout -------------------------------
# Pinned structurally rather than requested in a comment. If this ever reports
# INSIDE-repo-under-test, cases below may be reading the developer's real tree.
check "0  fixture root scope" "outside" "$(fixture_root_scope "$ROOT" "$FIX")"

# --- 1 / 1N. the base pair --------------------------------------------------
mk "$FIX/public/hit.md"   "$CANON"
mk "$FIX/public/clean.md" "$CLEAN"
check "1  outward path, registry term"    "WARN"  "$(verdict "$(run_hook "$FIX/public/hit.md")")"
check "1N outward path, no registry term" "QUIET" "$(verdict "$(run_hook "$FIX/public/clean.md")")"

# --- 2. ALIASES are scanned, not just canonical terms -----------------------
# This case exists because an earlier version extracted only the canonical
# "term" field. Every alias in the registry went unscanned, while the registry
# advertised them. Aliases matter more than they look: prose reaches for the
# natural phrasing, so the alias is often the form that actually gets written.
mk "$FIX/public/alias.md" "$ALIAS"
check "2  alias-only content warns" "WARN" "$(verdict "$(run_hook "$FIX/public/alias.md")")"

# --- 3 / 3N. exclusion ordering, and the control that makes 3 mean something -
# Path matches BOTH an exclusion (*/internal/*) and an inclusion (*/public/*).
# The exclusion must win, because it is tested first.
mk "$FIX/internal/public/dash.md" "$CANON"
mk "$FIX/public/dash.md"          "$CANON"
check "3  internal path excluded despite terms" "QUIET" "$(verdict "$(run_hook "$FIX/internal/public/dash.md")")"
check "3N same content, outward path, fires"    "WARN"  "$(verdict "$(run_hook "$FIX/public/dash.md")")"

# --- 4. FILENAME markers, not just directory segments -----------------------
# The gap this closes: files carrying their audience marker in the filename sat
# in an ordinary directory and matched no directory glob at all.
mk "$FIX/misc/investor_showcase.html" "$CANON"
check "4  filename marker outside marked dir" "WARN" "$(verdict "$(run_hook "$FIX/misc/investor_showcase.html")")"

# --- 5. singular vs plural directory ---------------------------------------
# One character of difference between `grant/` and `grants/` once cost total
# coverage of a live outward-facing directory, silently. Both are asserted so a
# future edit to the glob cannot quietly drop one.
mk "$FIX/grant/a.md"  "$CANON"
mk "$FIX/grants/b.md" "$CANON"
check "5  singular grant/ covered" "WARN" "$(verdict "$(run_hook "$FIX/grant/a.md")")"
check "5N plural grants/ covered"  "WARN" "$(verdict "$(run_hook "$FIX/grants/b.md")")"

# --- 6. matching is case-insensitive ---------------------------------------
# Git for Windows ships a grep that aborts on `-i -F` together, so the hook
# case-folds haystack and needle separately. This asserts the workaround still
# works rather than trusting the comment that describes it.
mk "$FIX/public/upper.md" "THIS MENTIONS PROJECT VANADIUM LOUDLY."
check "6  uppercase content still matches" "WARN" "$(verdict "$(run_hook "$FIX/public/upper.md")")"

# --- 7 / 7N. unscoped path stays quiet -------------------------------------
mk "$FIX/src/internals.md" "$CANON"
check "7  unscoped path quiet"            "QUIET" "$(verdict "$(run_hook "$FIX/src/internals.md")")"
check "7N same content under public/ fires" "WARN" "$(verdict "$(run_hook "$FIX/public/dash.md")")"

# --- 8 / 8N. missing registry degrades quietly ------------------------------
# Absent registry must not error or block. 8N is the control proving 8's silence
# comes from the missing file and not from a hook that stopped working.
check "8  missing registry stays quiet" "QUIET" "$(verdict "$(run_hook "$FIX/public/hit.md" "$FIX/nope.json")")"
check "8N present registry, same file"  "WARN"  "$(verdict "$(run_hook "$FIX/public/hit.md")")"

# --- 9. empty payload -------------------------------------------------------
# A payload with no file_path is normal, not an error. The hook must return
# empty and exit 0 rather than dying under the caller's `set -euo pipefail`.
out="$(printf '{}' | HOOK_TERM_REGISTRY="$REG" bash "$HOOK" 2>/dev/null)"; rc=$?
check "9  empty payload exits 0" "0" "$rc"
check "9b empty payload silent"  "QUIET" "$(verdict "$out")"

# --- 10. nonexistent file ---------------------------------------------------
check "10 nonexistent path quiet" "QUIET" "$(verdict "$(run_hook "$FIX/public/ghost.md")")"

echo
printf 'passed: %d  failed: %d  skipped: %d\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ] || exit 1
exit 0
