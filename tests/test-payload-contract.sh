#!/bin/bash
# Payload-contract bite-test for lib/payload.sh and every hook that consumes a
# tool payload through it.
#
# === The bug this guards ===
# A whole family of PostToolUse(Write|Edit) hooks read the edited path from
# $CLAUDE_TOOL_INPUT — a variable that is not part of the Claude Code hook
# contract and never was. Command hooks receive their input ONLY as JSON on
# stdin; the documented env vars are CLAUDE_PROJECT_DIR, CLAUDE_PLUGIN_ROOT,
# CLAUDE_PLUGIN_DATA, CLAUDE_EFFORT, CLAUDE_CODE_REMOTE and
# CLAUDE_CODE_BRIDGE_SESSION_ID. So the variable expanded empty, the path was
# empty, and every one of those hooks exited at its next line under
# `2>/dev/null || true`. The scanner whose job was checking outward-facing files
# before publication had never once looked at a file. It went unnoticed for
# months.
#
# It survived every audit because each audit invoked the hooks the way that
# WORKS (CLAUDE_TOOL_INPUT=… bash the-hook.sh) rather than the way they RUN
# (JSON on stdin, from a real tool call). The hooks are fail-open by design, so
# "found nothing" and "never ran" are the same observable. This file is what
# makes those two distinguishable.
#
# So the rule for anything added here: FEED THE CONTRACT. Every case pipes JSON
# on stdin with CLAUDE_TOOL_INPUT explicitly UNSET. A case that sets that
# variable to make a hook fire reproduces the bug it exists to catch.
#
# The load-bearing assertion is the POSITIVE one — that an in-scope file makes a
# consumer observably do something. Negative and degenerate cases only prove it
# fails quietly, which the broken version also did.
#
# === Division of labour with the per-hook suites ===
# This file owns the CHANNEL: stdin vs the env var, degenerate payloads, path
# shapes. What a given hook decides once it has the path belongs in that hook's
# own suite. The consumer used here is a real shipped hook, not a stand-in,
# because the whole lesson of the original defect is that a harness which invokes
# a hook conveniently proves nothing about how it runs.
#
# Run: bash tests/test-payload-contract.sh
# Exits non-zero on any failure. No deps beyond coreutils + bash.

set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$TESTS_DIR/../hooks" && pwd)"
LIB_DIR="$(cd "$TESTS_DIR/../lib" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
READER="$LIB_DIR/payload.sh"
CONSUMER="$HOOKS_DIR/term-scan.sh"
[ -f "$READER" ]   || { echo "FATAL: $READER not found"; exit 1; }
[ -f "$CONSUMER" ] || { echo "FATAL: $CONSUMER not found"; exit 1; }

. "$TESTS_DIR/lib/fixture-root.sh"
fixture_root_init payload

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


# A registry term pulled live from the example registry rather than hardcoded, so
# this file does not go stale (or falsely red) when that registry is edited.
REGISTRY="$ROOT/examples/terms.example.json"
TERM="$(grep -m1 '"term"' "$REGISTRY" \
        | sed -E 's/.*"term"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
[ -n "$TERM" ] || { echo "FATAL: could not read a term from the example registry"; exit 1; }

# --- fixtures ---------------------------------------------------------------
# `public/` is one of the consumer's outward-facing path segments; `ordinary.txt`
# matches none of them. Both files exist on disk, because the consumer checks
# that before doing anything — a non-existent path would exit early and every
# case would pass for the wrong reason.
mkdir -p "$FIX/public"
IN_SCOPE="$FIX/public/deliverable.md"
OUT_SCOPE="$FIX/ordinary.txt"
printf 'A document that mentions %s in passing.\n' "$TERM" > "$IN_SCOPE"
printf 'A document that mentions %s in passing.\n' "$TERM" > "$OUT_SCOPE"

payload() { printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1"; }

# Every invocation goes through here: stdin only, CLAUDE_TOOL_INPUT unset.
run_hook() { # <hook-path> <file>
  payload "$2" | env -u CLAUDE_TOOL_INPUT bash "$1" 2>&1
}

check() { # <label> <expected-regex, "" = silence> <actual>
  local label="$1" expect="$2" out="$3"
  if [ -z "$expect" ]; then
    if [ -z "$out" ]; then echo "  PASS  $label"; pass=$((pass+1))
    else echo "  FAIL  $label — expected silence, got:"; echo "$out" | sed 's/^/        /'; fail=$((fail+1)); fi
  else
    if echo "$out" | grep -qE "$expect"; then echo "  PASS  $label"; pass=$((pass+1))
    else echo "  FAIL  $label — expected /$expect/, got:"; echo "${out:-<silence>}" | sed 's/^/        /'; fail=$((fail+1)); fi
  fi
}
is() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1 — wanted [$2], got [$3]"; fail=$((fail+1)); fi
}

echo "payload contract — POSITIVE (the case that was broken: the hook must observably fire)"
check "term-scan.sh   in-scope file delivered on stdin" \
      "TERM-SCAN WARNING" "$(run_hook "$CONSUMER" "$IN_SCOPE")"

echo
echo "payload contract — stdin is the channel, not the env var"
# The precise assertion. If the reader still preferred CLAUDE_TOOL_INPUT it would
# resolve the decoy (out of scope, silent) and this would go red — which is
# exactly how the old code would have failed here on day one.
decoy="$(payload "$OUT_SCOPE")"
out="$(payload "$IN_SCOPE" | CLAUDE_TOOL_INPUT="$decoy" bash "$CONSUMER" 2>&1)"
if echo "$out" | grep -q "TERM-SCAN WARNING"; then
  echo "  PASS  term-scan.sh   stdin wins when the env var disagrees"; pass=$((pass+1))
else
  echo "  FAIL  term-scan.sh   the env var took precedence over stdin — the original defect"
  fail=$((fail+1))
fi
# The paired control, and the reason the case above is not tautological. With
# stdin EMPTY the variable is still honoured as a courtesy fallback, so a reader
# that ignored it outright would pass the case above for the wrong reason. If
# this one is silent while the one above passes, the reader is not consulting the
# variable at all and the "stdin wins" result carries no information about
# precedence. stdin is the contract; the variable is a courtesy.
out="$(printf '' | CLAUDE_TOOL_INPUT="$(payload "$IN_SCOPE")" bash "$CONSUMER" 2>&1)"
check "control: empty stdin still falls back to the env var" "TERM-SCAN WARNING" "$out"

echo
echo "payload contract — NEGATIVE (out of scope stays silent; no new noise)"
# Same file contents, same registry term, only the path differs. Pairs with the
# positive case above: together they show the silence is a scope decision and not
# a hook that has stopped running.
check "term-scan.sh   out-of-scope path" "" "$(run_hook "$CONSUMER" "$OUT_SCOPE")"

echo
echo "payload contract — DEGENERATE (must exit 0, never crash)"
for case_name in empty no-path malformed not-json; do
  case "$case_name" in
    empty)     body='' ;;
    no-path)   body='{"tool_name":"Write","tool_input":{"content":"no path here"}}' ;;
    malformed) body='{"tool_input":' ;;
    not-json)  body='this is not json at all' ;;
  esac
  printf '%s' "$body" | env -u CLAUDE_TOOL_INPUT bash "$CONSUMER" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then echo "  PASS  term-scan.sh   $case_name payload -> exit 0"; pass=$((pass+1))
  else echo "  FAIL  term-scan.sh   $case_name payload -> exit $rc"; fail=$((fail+1)); fi
done

echo
echo "payload contract — the errexit hazard the reader's trailing '|| true' exists for"
# A consumer running under `set -euo pipefail` is the dangerous shape: a no-match
# `grep` returns 1, pipefail promotes it to the pipeline's status, and errexit
# then kills the script ON THE ASSIGNMENT LINE. That mechanism left one gate in
# this layer silent for a month. No shipped hook here runs under errexit today,
# so the hazard has no coverage unless the harness supplies the shape — which is
# what this probe is for. It is deliberately minimal: source the reader, take the
# path, report. If the reader ever loses its trailing `|| true`, this goes red
# and nothing else in the repo would.
PROBE="$FIX/errexit-probe.sh"
cat > "$PROBE" <<PROBE_EOF
#!/usr/bin/env bash
set -euo pipefail
. "$READER"
PAYLOAD="\$(hook_payload)"
FILE="\$(hook_file_path "\$PAYLOAD")"
printf 'resolved:[%s]\n' "\$FILE"
exit 0
PROBE_EOF
chmod +x "$PROBE"

out="$(payload "$IN_SCOPE" | env -u CLAUDE_TOOL_INPUT bash "$PROBE" 2>&1)"
is "errexit consumer resolves a present path" "resolved:[$IN_SCOPE]" "$out"
# The half that actually reproduces the bug: a payload with NO file_path is
# normal, not an error, and must come back empty at exit 0 rather than killing
# the caller on its assignment line.
out="$(printf '{"tool_input":{"content":"x"}}' | env -u CLAUDE_TOOL_INPUT bash "$PROBE" 2>&1)"
is "errexit consumer survives a payload with no file_path" "resolved:[]" "$out"

echo
echo "payload contract — the extractor's own shapes"
# Asserted directly, because a consumer can only ever show that SOME path came
# back. These pin WHICH one, and they are the shapes real payloads arrive in.
# Sourced into THIS shell rather than a subshell — a subshell would swallow every
# pass/fail increment and the block would report nothing while looking green,
# which is the failure mode this whole file is about.
. "$READER"
is "nested tool_input.file_path is found" "/a/b.md" \
   "$(hook_file_path '{"tool_name":"Write","tool_input":{"file_path":"/a/b.md"}}')"
is "a flat {file_path:...} object works too" "/a/c.md" \
   "$(hook_file_path '{"file_path":"/a/c.md"}')"
# The `([^"\\]|\\.)*` capture is load-bearing: without it the match truncates at
# an escaped quote inside the value and returns half a path.
is "an escaped quote inside the value does not truncate the match" '/a/q"x.md' \
   "$(hook_file_path '{"tool_input":{"file_path":"/a/q\"x.md"}}')"
is "no file_path yields empty, not garbage" "" \
   "$(hook_file_path '{"tool_input":{"content":"x"}}')"
is "empty input yields empty" "" "$(hook_file_path '')"

echo
echo "payload contract — Windows path shape (real payloads carry doubled backslashes)"
# cygpath gives the real native form (C:\Users\…), which is what a Write payload
# actually carries there. Building one by string-substituting the MSYS path
# instead produces \tmp\… — not a real path, so the case would "pass" by skipping
# and prove nothing. Off Windows there is no such shape to test and the skip is
# legitimate.
if command -v cygpath >/dev/null 2>&1; then
  native="$(cygpath -w "$IN_SCOPE")"
  win_path="$(printf '%s' "$native" | sed 's|\\|\\\\|g')"   # JSON-escape: \ -> \\
  out="$(printf '{"tool_input":{"file_path":"%s"}}' "$win_path" \
         | env -u CLAUDE_TOOL_INPUT bash "$CONSUMER" 2>&1)"
  if echo "$out" | grep -q "TERM-SCAN WARNING"; then
    echo "  PASS  term-scan.sh   escaped-backslash native path resolves and scans"; pass=$((pass+1))
  else
    echo "  FAIL  term-scan.sh   native path $native did not resolve:"; echo "${out:-<silence>}" | sed 's/^/        /'; fail=$((fail+1))
  fi
else
  echo "  SKIP  term-scan.sh   no cygpath — not a Windows shell, nothing to test"; skip=$((skip+1))
fi

echo
echo "payload contract — fixture hygiene"
# The fixtures must sit outside the checkout under test. A consumer whose scope
# filter matched something in this repo's own tree would make the negative cases
# report on the repo rather than on the fixture.
is "fixture root sits outside the checkout under test" outside \
   "$(fixture_root_scope "$LIB_DIR" "$FIX")"

echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail   skipped: $skip"
[ "$fail" -eq 0 ] || exit 1
