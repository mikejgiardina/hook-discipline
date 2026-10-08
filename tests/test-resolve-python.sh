#!/bin/bash
# Contract tests for lib/resolve-python.sh.
#
# === What makes this file non-vacuous ===
# The defect is "a hook picks an interpreter that resolves but does not run."
# A suite that only asserts "resolve_python found something" would pass just as
# happily against the broken code, because the broken code also finds something
# — that is the whole bug. So case 1 is a POSITIVE CONTROL: it runs the OLD
# one-liner against the same fixture and asserts it picks the DEAD stub.
#
# If case 1 ever goes green-by-failing (i.e. the old pattern stops selecting the
# stub), the fixture has stopped reproducing the bug and every later assertion
# here is worthless. Case 1 failing is therefore a louder signal than any other
# failure in this file, and it is deliberately first.
#
# This matters here more than most places: a whole family of Write|Edit hooks in
# this layer was wired, green, and doing nothing for a month, because nothing
# ever checked that the thing under test could fail.
#
# Run: bash tests/test-resolve-python.sh

set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$TESTS_DIR/../hooks" && pwd)"
LIB_DIR="$(cd "$TESTS_DIR/../lib" && pwd)"
HELPER="$LIB_DIR/resolve-python.sh"
[ -f "$HELPER" ] || { echo "FATAL: $HELPER not found"; exit 1; }

# The fixture dirs are PREPENDED to PATH, so the root has to be a form bash's own
# PATH lookup can use. The shared helper guarantees that (and keeps the tree out
# of the checkout under test); see tests/lib/fixture-root.sh.
. "$TESTS_DIR/lib/fixture-root.sh"
fixture_root_init rp
FIXDIR="$FIX"
mkdir -p "$FIXDIR/winstub" "$FIXDIR/macos" "$FIXDIR/nothing"

# === A documented escape hatch can route around a test's own interposition ===
# Almost every case below works by interposing a fake interpreter on PATH and
# asserting which one resolve_python picks. That entire technique is silently
# defeated by an ambient HOOK_PYTHON, because the pin is honoured FIRST, before
# any PATH lookup happens. With it set in the environment, the stubs are never
# consulted and every case tests the pin instead — passing, while measuring
# nothing it claims to measure.
#
# This is not hypothetical. The same shape, in a sibling suite, meant an
# interposed CLI shim was bypassed, the real CLI ran, and the test fired a live
# mutation against a production system while reporting green.
#
# So: unset it, and ASSERT that it is unset. The assertion is the point — an
# `unset` on its own is a request that a future edit can quietly undo, and the
# two cases that legitimately set the pin do so per-invocation, further down.
unset HOOK_PYTHON

# The resolver caches a clean discovery in a file. Every case here points that
# cache at a file inside the fixture: left at its default, the cases would share
# the caller's real cache, and an entry written there by an earlier hook could
# answer for a stub this suite interposes. The TTL is pinned to its default.
export RESOLVE_PYTHON_CACHE="$FIXDIR/rp.cache"
unset RESOLVE_PYTHON_CACHE_TTL

pass=0; fail=0; skip=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
no()   { echo "  FAIL  $1"; fail=$((fail+1)); }
is()   { # $1=label $2=want $3=got
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 — wanted [$2], got [$3]"; fi
}

# --- fixtures ---------------------------------------------------------------
# The Windows shape: a python3 that RESOLVES and FAILS, beside a python that works.
# The exit code and wording are copied from the real App-Execution-Alias stub so
# the fixture fails the same way the real thing does, not merely some way.
cat > "$FIXDIR/winstub/python3" <<'STUB'
#!/bin/sh
echo "Python was not found; run without arguments to install from the Microsoft Store, or disable this shortcut from Settings > Manage App Execution Aliases."
exit 49
STUB
cat > "$FIXDIR/winstub/python" <<'REAL'
#!/bin/sh
echo "Python 3.13.14"
REAL

# The macOS shape: python3 works, no bare python exists at all.
cat > "$FIXDIR/macos/python3" <<'REAL'
#!/bin/sh
echo "Python 3.12.4"
REAL

# Neither candidate works. BOTH names must be shadowed, not just python3.
#
# These fixture dirs are PREPENDED to the real PATH rather than replacing it —
# replacing it removes `bash` itself and every case exits 127, which reads as a
# failure of the helper when it is really a failure of the harness. Because
# `command -v` returns the FIRST match, shadowing both names is what makes the
# real interpreters further down PATH unreachable.
cat > "$FIXDIR/nothing/python3" <<'STUB'
#!/bin/sh
echo "Python was not found; run without arguments to install from the Microsoft Store."
exit 49
STUB
cp "$FIXDIR/nothing/python3" "$FIXDIR/nothing/python"

# A python2 shape, to pin that the probe checks the MAJOR VERSION and not merely
# that the binary exits 0. `python --version` on py2 writes to stderr, which is
# also why the helper probes with 2>&1.
mkdir -p "$FIXDIR/py2"
cat > "$FIXDIR/py2/python" <<'P2'
#!/bin/sh
echo "Python 2.7.18" >&2
P2
cp "$FIXDIR/nothing/python3" "$FIXDIR/py2/python3"   # shadow python3 too

chmod +x "$FIXDIR"/*/python3 "$FIXDIR"/*/python 2>/dev/null

echo "resolve-python.sh — interpreter probing"
echo

# --- 0. the interposition is not being routed around ------------------------
# Asserted, not assumed. If HOOK_PYTHON is set, resolve_python honours it before
# consulting PATH at all, and every PATH-interposition case below silently
# measures the pin instead of its stub — passing throughout.
echo "preconditions"
if [ -z "${HOOK_PYTHON:-}" ]; then
  ok "HOOK_PYTHON is unset, so PATH interposition is what is being measured"
else
  no "HOOK_PYTHON is set ([$HOOK_PYTHON]) — the pin outranks PATH, so every
        interposition case below is measuring the pin, not its stub"
fi
case "${RESOLVE_PYTHON_CACHE:-}" in
  "$FIXDIR"/*) ok "the probe cache under test lives inside the fixture" ;;
  *)           no "RESOLVE_PYTHON_CACHE is [${RESOLVE_PYTHON_CACHE:-}], not a fixture path" ;;
esac
echo

# --- 1. POSITIVE CONTROL: the old pattern must pick the dead stub ------------
# Read this as "does the fixture still reproduce the bug?", not as a test of the
# fix.
echo "positive control — the fixture must still reproduce the bug"
OLD="$(PATH="$FIXDIR/winstub:$PATH" bash -c 'command -v python3 || command -v python || true')"
case "$OLD" in
  */winstub/python3)
    ok "old one-liner selects the dead stub (fixture reproduces the bug)" ;;
  *)
    no "old one-liner did NOT select the stub (got [$OLD]) — fixture is not reproducing the bug;
        every assertion below this line is vacuous until this is fixed" ;;
esac
# And confirm the thing it selected is genuinely dead, so "stub" is not just a name.
if PATH="$FIXDIR/winstub:$PATH" bash -c '"$(command -v python3)" --version' >/dev/null 2>&1; then
  no "the stub fixture exits 0 — it is not simulating a dead interpreter"
else
  ok "the selected stub really fails to run (non-zero exit)"
fi

echo
echo "resolve_python must skip what does not run"

# --- 2. the fix: skip the stub, land on the working python -------------------
GOT="$(PATH="$FIXDIR/winstub:$PATH" bash -c ". '$HELPER'; resolve_python")"
case "$GOT" in
  */winstub/python) ok "Windows shape: skips the stub, selects the working python" ;;
  *)                no "Windows shape: wanted */winstub/python, got [$GOT]" ;;
esac

# --- 3. ordering is preserved: python3 still wins when it works --------------
GOT="$(PATH="$FIXDIR/macos:$PATH" bash -c ". '$HELPER'; resolve_python")"
case "$GOT" in
  */macos/python3) ok "macOS shape: python3-first ordering preserved" ;;
  *)               no "macOS shape: wanted */macos/python3, got [$GOT]" ;;
esac

# --- 4. nothing works -> empty output AND non-zero exit ----------------------
# Both halves matter. Callers branch on emptiness ([ -z "$PY" ]); the `|| echo
# python` callers branch on the exit status. A helper that got one right and the
# other wrong would fix half the call sites and silently break the other half.
OUT="$(PATH="$FIXDIR/nothing:$PATH" bash -c ". '$HELPER'; resolve_python" 2>/dev/null)"; RC=$?
is  "no working python: exit status is 1" "1" "$RC"
is  "no working python: output is empty"  ""  "$OUT"

# --- 5. python2 is rejected --------------------------------------------------
OUT="$(PATH="$FIXDIR/py2:$PATH" bash -c ". '$HELPER'; resolve_python" 2>/dev/null)"; RC=$?
is "python2 is rejected (probe checks the major version, not the exit code)" "1" "$RC"

echo
echo "caller shapes must keep their existing posture"

# --- 6. the two wrapper forms used at the call sites -------------------------
# `|| echo python` sites must still end up with the literal last resort.
GOT="$(PATH="$FIXDIR/nothing:$PATH" bash -c ". '$HELPER'; PY=\"\$(resolve_python || echo python)\"; printf %s \"\$PY\"" 2>/dev/null)"
is "advisory shape: \$(resolve_python || echo python) falls back to literal python" "python" "$GOT"

# `|| true` sites must end up empty so their own [ -z "$PY" ] branch fires.
GOT="$(PATH="$FIXDIR/nothing:$PATH" bash -c ". '$HELPER'; PY=\"\$(resolve_python || true)\"; printf %s \"\$PY\"" 2>/dev/null)"
is "gate shape: \$(resolve_python || true) yields empty for the [ -z ] branch" "" "$GOT"

# Sourcing must not blow up a `set -euo pipefail` caller. Several hooks run under
# errexit, where a helper that returns non-zero at source time would kill the
# script on its source line — the same mechanism that left one gate in this layer
# silent for a month.
if PATH="$FIXDIR/nothing:$PATH" bash -c "set -euo pipefail; . '$HELPER'; PY=\"\$(resolve_python || echo python)\"; [ \"\$PY\" = python ]" 2>/dev/null; then
  ok "sourcing is safe under set -euo pipefail"
else
  no "sourcing under set -euo pipefail killed the caller"
fi

echo
echo "HOOK_PYTHON pin"

# --- 7. pin honoured, bad pin ignored loudly --------------------------------
GOT="$(PATH="$FIXDIR/nothing:$PATH" HOOK_PYTHON="$FIXDIR/winstub/python" bash -c ". '$HELPER'; resolve_python" 2>/dev/null)"
is "a working HOOK_PYTHON pin is used verbatim" "$FIXDIR/winstub/python" "$GOT"

ERR="$(PATH="$FIXDIR/macos:$PATH" HOOK_PYTHON="$FIXDIR/winstub/python3" bash -c ". '$HELPER'; resolve_python" 2>&1 >/dev/null)"
case "$ERR" in
  *"did not answer"*) ok "a dead HOOK_PYTHON pin warns on stderr" ;;
  *)                  no "a dead pin was ignored silently (stderr: [$ERR])" ;;
esac
GOT="$(PATH="$FIXDIR/macos:$PATH" HOOK_PYTHON="$FIXDIR/winstub/python3" bash -c ". '$HELPER'; resolve_python" 2>/dev/null)"
case "$GOT" in
  */macos/python3) ok "a dead pin degrades to discovery rather than wedging the hook" ;;
  *)               no "dead pin: wanted fallback to */macos/python3, got [$GOT]" ;;
esac

echo
echo "the raw pattern must not creep back in"

# --- 8. repo-wide regression guard ------------------------------------------
# Patching the call sites and leaving the pattern in circulation means the next
# hook authored to the old spec reintroduces the bug on day one. This asserts the
# pattern is gone from the shipped scripts. Test fixtures and this file are
# excluded (they must be able to SPELL the old pattern in order to control for
# it), as is the helper itself.
#
# It matches the COMPOSITE anti-pattern (`command -v python3 || command -v
# python`), not any use of `command -v python3`. A bare `command -v python3` is
# legitimate: a diagnostic that locates the stub in order to REPORT that a stub
# was skipped needs exactly that, and grepping the narrower string flagged such a
# line as the very defect it exists to surface.
STRAY="$(grep -ln 'command -v python3 *|| *command -v python' \
           "$HOOKS_DIR"/*.sh "$LIB_DIR"/*.sh 2>/dev/null \
         | grep -v '/resolve-python\.sh$' || true)"
if [ -z "$STRAY" ]; then
  ok "no shipped script still resolves python with the raw command -v one-liner"
else
  no "these scripts still carry the raw pattern:
$(printf '%s\n' "$STRAY" | sed 's|.*/|        |')"
fi

# Every script that USES $PY must source the helper. Catches the reverse mistake:
# deleting the old line without adding the new one, which yields an unbound PY.
MISSING=""
for f in "$HOOKS_DIR"/*.sh "$LIB_DIR"/*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in resolve-python.sh|payload.sh) continue ;; esac
  grep -q 'resolve_python' "$f" 2>/dev/null || continue
  grep -q 'resolve-python\.sh' "$f" 2>/dev/null || MISSING="$MISSING $(basename "$f")"
done
if [ -z "$MISSING" ]; then
  ok "every script calling resolve_python also sources the helper"
else
  no "call resolve_python without sourcing the helper:$MISSING"
fi

echo
echo "mirroring tests must carry the helper"

# --- 9. the regression the original sweep actually caused --------------------
# Several test files MIRROR their hook into a throwaway fixture directory and run
# the copy, so the registry and paths it derives land in the fixture instead of
# the real tree. A mirrored hook resolves its sibling helper relative to its own
# location — inside the FIXTURE, where the helper does not exist unless it is
# copied too.
#
# When it is missing the source fails, resolve_python is undefined, PY comes back
# empty, and the hook takes its no-python branch — for the advisory hooks a
# SILENT exit 0. Every such file went from green to red the moment the sweep
# landed, and the only reason that was caught rather than shipped is that they
# had real assertions to go red. A test file added later with weaker assertions
# would simply have passed while testing nothing.
#
# So this check is static and derived: for each test whose target hook sources
# the helper, the test must copy the helper. Nothing here is hardcoded to the
# known files — a new one gets caught the day it is written.
MISSING_MIRROR=""
for t in "$TESTS_DIR"/test-*.sh; do
  tb="$(basename "$t")"
  target="$HOOKS_DIR/${tb#test-}"                # test-foo.sh -> hooks/foo.sh
  [ -f "$target" ] || continue                   # contract/helper tests have no hook
  # Does the TARGET actually source the helper? Anchored to a real `.`/`source`
  # statement, not a bare mention of the filename.
  #
  # That anchoring is not fussiness. A hook here once stopped sourcing the helper
  # (it had been resolving an interpreter it never used) and the deletion left
  # behind a comment saying so — which still contains the string
  # `resolve-python.sh`. A bare `grep -q` therefore kept classifying that hook as
  # helper-dependent, demanded its test mirror a file it no longer needed, and
  # reported a missing mirror for a dependency that did not exist.
  #
  # That is precisely the failure the comment a few lines below describes, on the
  # OTHER half of this same check — where it was anticipated and guarded.
  # Grepping for a filename finds prose about the filename. Worth stating twice,
  # since this check has now been written the wrong way twice.
  grep -qE '^[[:space:]]*(\.|source)[[:space:]].*resolve-python\.sh' "$target" || continue
  # Does this test mirror the hook (rather than invoke it in place)?
  grep -qE 'cp "\$(REAL_HOOK|SRC|HOOK)"' "$t" || continue
  # Must be an actual `cp` OF THE HELPER. Grepping for the bare filename matches
  # the comment that explains why the copy is there, so removing the copy and
  # leaving the comment would still pass — this check was written that way first
  # and its own negative control caught it.
  grep -qE '^[[:space:]]*cp .*resolve-python\.sh' "$t" || MISSING_MIRROR="$MISSING_MIRROR $tb"
done
if [ -z "$MISSING_MIRROR" ]; then
  ok "every test that mirrors a helper-sourcing hook also mirrors the helper"
else
  no "mirror the hook but not resolve-python.sh (their assertions will go vacuous):$MISSING_MIRROR"
fi

echo
echo "probe cache"

# --- 10. a clean discovery is cached; anything that could change it re-probes --
# A hook is a fresh process, so the cache is a file, and each call below runs in
# its own bash exactly as two hook invocations would. The counting stub logs
# every `--version` it answers, so "was it probed?" is measured, not inferred.
#
# Each miss case sits next to a control showing the same setup HITS when nothing
# changed. Without that, a cache that never hits passes every miss case.
mkdir -p "$FIXDIR/count" "$FIXDIR/shadow" "$FIXDIR/pin"
cat > "$FIXDIR/count/python3" <<'CNT'
#!/bin/sh
echo x >> "$PROBE_LOG"
echo "Python 3.13.14"
CNT
cp "$FIXDIR/nothing/python" "$FIXDIR/count/python"   # shadow any real bare python
cp "$FIXDIR/count/python3" "$FIXDIR/pin/python3"
chmod +x "$FIXDIR/count/python3" "$FIXDIR/count/python" "$FIXDIR/pin/python3"
export PROBE_LOG="$FIXDIR/probes.log"
C="$FIXDIR/cache10"

probes() { if [ -f "$PROBE_LOG" ]; then grep -c x "$PROBE_LOG"; else echo 0; fi; }
rp() { # $1=cache path
  PATH="$FIXDIR/count:$PATH" RESOLVE_PYTHON_CACHE="$1" bash -c ". '$HELPER'; resolve_python" 2>/dev/null
}
# GNU touch takes -d @epoch; BSD touch (macOS) does not, but BSD date -r does.
set_mtime() { # $1=epoch $2=file
  touch -d "@$1" "$2" 2>/dev/null || touch -t "$(date -r "$1" +%Y%m%d%H%M.%S)" "$2"
}
# Interpreters older than any cache file this section writes, so only the case
# that means to can make one look upgraded.
set_mtime $(( $(date +%s) - 60 )) "$FIXDIR/count/python3"
set_mtime $(( $(date +%s) - 60 )) "$FIXDIR/pin/python3"

: > "$PROBE_LOG"; rm -f "$C"
G1="$(rp "$C")"; G2="$(rp "$C")"
case "$G1" in
  */count/python3) ok "cache: the first call discovers the counting stub" ;;
  *)               no "cache: first call wanted */count/python3, got [$G1]" ;;
esac
is "cache: the second call returns the same interpreter" "$G1" "$G2"
is "cache: two calls probe once" "1" "$(probes)"

# An upgrade, reinstall or re-pointed alias leaves a newer file behind.
: > "$PROBE_LOG"
set_mtime $(( $(date +%s) + 120 )) "$FIXDIR/count/python3"
if [ "$FIXDIR/count/python3" -nt "$C" ]; then
  rp "$C" >/dev/null
  is "cache: an interpreter newer than the cache re-probes" "1" "$(probes)"
else
  no "cache: could not future-date the stub, so the newer-interpreter case did not run"
fi
# Back into the past. Left future-dated, the stub would make EVERY later lookup a
# miss, and each miss case below would pass without the cache ever able to hit.
set_mtime $(( $(date +%s) - 60 )) "$FIXDIR/count/python3"

: > "$PROBE_LOG"
rp "$C" >/dev/null
is "cache: control — an unchanged PATH is a hit" "0" "$(probes)"
G3="$(PATH="$FIXDIR/macos:$FIXDIR/count:$PATH" RESOLVE_PYTHON_CACHE="$C" bash -c ". '$HELPER'; resolve_python" 2>/dev/null)"
case "$G3" in
  */macos/python3) ok "cache: a PATH change is a miss (new answer)" ;;
  *)               no "cache: a PATH change returned [$G3], wanted */macos/python3" ;;
esac

# A new interpreter SHADOWING the cached one under the identical PATH string. The
# key has to carry what each name resolves to, not PATH alone; the control first
# shows this exact PATH hitting, so a PATH-only key cannot pass by missing.
SHP="$FIXDIR/shadow:$FIXDIR/count:$PATH"
rm -f "$C"; : > "$PROBE_LOG"
PATH="$SHP" RESOLVE_PYTHON_CACHE="$C" bash -c ". '$HELPER'; resolve_python" >/dev/null 2>&1
PATH="$SHP" RESOLVE_PYTHON_CACHE="$C" bash -c ". '$HELPER'; resolve_python" >/dev/null 2>&1
is "cache: control — the shadow PATH hits before anything is added to it" "1" "$(probes)"
cp "$FIXDIR/winstub/python3" "$FIXDIR/shadow/python3"; chmod +x "$FIXDIR/shadow/python3"
G5="$(PATH="$SHP" RESOLVE_PYTHON_CACHE="$C" bash -c ". '$HELPER'; resolve_python" 2>/dev/null)"
rm -f "$FIXDIR/shadow/python3"
case "$G5" in
  */count/python3) no "cache: returned the cached interpreter past a new shadowing python3" ;;
  *)               ok "cache: a new interpreter shadowing the cached one on the same PATH is a miss" ;;
esac

# A deleted interpreter. A pin keeps the key identical after the deletion, so the
# executable check is the only thing standing between the caller and a dead path.
rpin() {
  PATH="$FIXDIR/count:$PATH" HOOK_PYTHON="$FIXDIR/pin/python3" RESOLVE_PYTHON_CACHE="$C" \
    bash -c ". '$HELPER'; resolve_python" 2>/dev/null
}
rm -f "$C"; : > "$PROBE_LOG"
rpin >/dev/null; P2="$(rpin)"
is "cache: control — a working pin is cached (second call is a hit)" "1:$FIXDIR/pin/python3" "$(probes):$P2"
mv "$FIXDIR/pin/python3" "$FIXDIR/pin/python3.gone"
OUT="$(rpin)"
mv "$FIXDIR/pin/python3.gone" "$FIXDIR/pin/python3"
case "$OUT" in
  */pin/python3)   no "cache: returned a deleted interpreter [$OUT]" ;;
  */count/python3) ok "cache: a deleted interpreter is never returned (rediscovers)" ;;
  *)               no "cache: deleted pin gave [$OUT], wanted rediscovery of */count/python3" ;;
esac

printf 'garbage\n\n' > "$C"; : > "$PROBE_LOG"
G4="$(rp "$C")"
case "$(probes):$G4" in
  1:*/count/python3) ok "cache: a corrupt cache file is ignored (re-probes, right answer)" ;;
  *)                 no "cache: corrupt file gave [$G4] after $(probes) probe(s)" ;;
esac

: > "$PROBE_LOG"
rp "" >/dev/null; rp "" >/dev/null
is "cache: RESOLVE_PYTHON_CACHE='' disables it (probes every call)" "2" "$(probes)"

# Only clean discoveries are stored. Were the fallback after a dead pin cached,
# the second call would hit and the operator would hear about the pin once.
rm -f "$C"
E1="$(PATH="$FIXDIR/macos:$PATH" HOOK_PYTHON="$FIXDIR/winstub/python3" RESOLVE_PYTHON_CACHE="$C" bash -c ". '$HELPER'; resolve_python" 2>&1 >/dev/null)"
E2="$(PATH="$FIXDIR/macos:$PATH" HOOK_PYTHON="$FIXDIR/winstub/python3" RESOLVE_PYTHON_CACHE="$C" bash -c ". '$HELPER'; resolve_python" 2>&1 >/dev/null)"
case "$E1" in *"did not answer"*) w1=yes ;; *) w1=no ;; esac
case "$E2" in *"did not answer"*) w2=yes ;; *) w2=no ;; esac
is "cache: a dead pin is never cached (warns on every call)" "yes:yes" "$w1:$w2"

# The TTL bounds how long an interpreter that broke without any file changing can
# still be returned. Line 3 of the cache is the entry's epoch.
rm -f "$C"; : > "$PROBE_LOG"
rp "$C" >/dev/null
if [ -f "$C" ]; then
  l1=""; l2=""
  { IFS= read -r l1; IFS= read -r l2; } < "$C"
  printf '%s\n%s\n%s\n' "$l1" "$l2" 1000 > "$C"
  rp "$C" >/dev/null
  is "cache: an expired entry re-probes" "2" "$(probes)"
else
  no "cache: nothing was stored, so the expired-entry case did not run"
fi

rm -f "$C"; : > "$PROBE_LOG"
RESOLVE_PYTHON_CACHE_TTL=abc rp "$C" >/dev/null; RESOLVE_PYTHON_CACHE_TTL=abc rp "$C" >/dev/null
is "cache: a non-numeric TTL falls back to the default (second call hits)" "1" "$(probes)"
rm -f "$C"; : > "$PROBE_LOG"
RESOLVE_PYTHON_CACHE_TTL=0 rp "$C" >/dev/null; RESOLVE_PYTHON_CACHE_TTL=0 rp "$C" >/dev/null
is "cache: a zero TTL never hits" "2" "$(probes)"

# A directory at the cache path: never write into or beside it, still answer.
mkdir -p "$FIXDIR/cdir"
G6="$(rp "$FIXDIR/cdir")"
LEFT="$(ls -A "$FIXDIR/cdir")$(ls "$FIXDIR" | grep '^cdir\..*\.tmp$' || true)"
case "$G6:$LEFT" in
  */count/python3:) ok "cache: a directory at the cache path is left alone" ;;
  *)                no "cache: directory cache path gave [$G6], left behind [$LEFT]" ;;
esac

# Miss and hit both under a strict caller, with a corrupt file to start from.
printf 'garbage\n' > "$C"
if PATH="$FIXDIR/count:$PATH" RESOLVE_PYTHON_CACHE="$C" bash -c "set -euo pipefail; . '$HELPER'
     resolve_python >/dev/null; resolve_python >/dev/null
     a=\"\$(resolve_python)\"; [ -n \"\$a\" ]" 2>/dev/null; then
  ok "cache: miss and hit are safe under set -euo pipefail"
else
  no "cache: a set -euo pipefail caller died on the miss or hit path"
fi
unset PROBE_LOG

echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail   skipped: $skip"
[ "$fail" -eq 0 ] || exit 1
