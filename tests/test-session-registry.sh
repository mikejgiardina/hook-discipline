#!/bin/bash
# Behavioral tests for hooks/session-registry.sh — the live-session registry.
#
# === Why this hook matters ===
# Branch-per-thread isolates BRANCHES but not the WORKING TREE. When two agent
# sessions run against the same workspace they share the checkout, and
# `git checkout` plus uncommitted changes are global to a tree — which here
# produced commits landing on another session's branch and threads split
# mid-commit. Per-session worktrees are the fix; this registry is the
# warn-the-agent half that makes the agent actually take one.
#
# It is also load-bearing for two OTHER hooks, which is what raises the cost of a
# regression above "one missing warning":
#   - worktree-guard.sh reads it to decide whether to warn about a peer session
#   - a second consumer reads it for liveness, one of the two signals guarding
#     against taking over a live session's lock
# So a session that silently fails to register degrades three things at once, and
# the observable in every case is the ABSENCE of a warning.
#
# === A test only sees the axis it varies ===
# This hook's implicit axis is SESSION IDENTITY RESOLUTION, and it has already
# failed there: the env fallback read `CLAUDE_SESSION_ID` alone, which this build
# never sets, so any payload without a session_id fell straight through to the
# anonymous exit and the session went UNREGISTERED — silently, degrading both
# consumers with it. Fixed later by reading CLAUDE_CODE_SESSION_ID first. Block I
# varies that axis directly; every other case in this file passes under the old
# bug, because they all supply a session_id in the payload.
#
# The second implicit axis is TIME. Staleness pruning is what stops a crashed
# session warning forever, and it is unobservable without moving the clock — so
# block T writes registry entries with backdated heartbeats rather than waiting.
#
# === Paired positive control ===
# The warning's ABSENCE is the common, correct case, so an all-quiet suite is
# what a dead hook produces. Every quiet expectation is paired with a fire built
# from the same registry state through the same harness: T1/T2 hold the peer
# entry constant and move only its heartbeat across the staleness boundary, and
# I2/I3 hold the peer constant and move only where the session id comes from.
#
# Hermetic: mirrors the hook into a throwaway directory so the registry it reads
# and writes is a fixture, never this machine's real .session-registry.json —
# which is live, gitignored, and may be tracking other sessions right now.
# Run: bash tests/test-session-registry.sh

set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_DIR="$(cd "$TESTS_DIR/../hooks" && pwd)"
LIB_DIR="$(cd "$TESTS_DIR/../lib" && pwd)"
REAL_HOOK="$HOOK_DIR/session-registry.sh"
[ -f "$REAL_HOOK" ] || { echo "FATAL: $REAL_HOOK not found"; exit 1; }
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "FATAL: python required — the hook shells out to it"; exit 1; }

# Fixture root sits outside the checkout under test. Rationale and the Windows
# path caveat live in tests/lib/fixture-root.sh.
#
# Per-suite verdict: LATENT, deliberately -- and resting on a single line. The hook
# derives its registry path from its own BASH_SOURCE, so the mirror below is what
# makes REG land in $FIX instead of the machine's live session registry. The hook
# never calls git and never dereferences the payload's cwd (it stores it as a
# string), so the root's location is otherwise inert.
#
# The fragility is worth recording: move REG to anything BASH_SOURCE-independent --
# CLAUDE_PROJECT_DIR, `git rev-parse --show-toplevel`, an upward marker walk -- and
# the mirror stops shielding anything, at which point this suite would be mutating
# every live session's registry on the machine. Case Z asserts the separation
# rather than assuming it.
. "$TESTS_DIR/lib/fixture-root.sh"
fixture_root_init sessreg
mkdir -p "$FIX/hooks" "$FIX/lib"
cp "$REAL_HOOK" "$FIX/hooks/session-registry.sh"
# The mirrored hook sources ../lib/resolve-python.sh relative to its own
# location. Without this copy the source fails, resolve_python is undefined, PY
# comes back empty and the hook takes its no-python branch -- which for the
# advisory hooks is a SILENT exit 0. Every assertion then passes-by-not-running,
# which is the exact shape this suite exists to rule out.
cp "$LIB_DIR/resolve-python.sh" "$FIX/lib/"
HOOK="$FIX/hooks/session-registry.sh"
# REG is derived as "<dir of the script>/.session-registry.json", so mirroring
# the hook is what redirects the registry. Getting this wrong would have the
# suite mutating the live registry of every other session on this machine.
REG="$FIX/hooks/.session-registry.json"

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


payload() { # <session_id> [cwd]
  printf '{"session_id":"%s","cwd":"%s"}' "$1" "${2:-$FIX}"
}
# Every invocation unsets both session-id env vars, because this suite may run
# inside a live agent session that exports CLAUDE_CODE_SESSION_ID. Inheriting it
# would make the anonymous case (I6) unreachable and let the fallback cases pass
# on the ambient value instead of the one under test.
run() { # <mode> <payload> [env assignments...]
  local mode="$1" pl="$2"; shift 2
  printf '%s' "$pl" | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    "$@" bash "$HOOK" "$mode" 2>/dev/null
}
run_err() {
  local mode="$1" pl="$2"; shift 2
  printf '%s' "$pl" | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
    "$@" bash "$HOOK" "$mode" 2>&1 >/dev/null
}

verdict() {
  if printf '%s' "$1" | grep -q 'WORKTREE GUARD'; then printf 'WARNED'; else printf 'QUIET'; fi
}
check() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1 — expected $2, got $3"; fail=$((fail+1)); fi
}
# Is <sid> present in the registry? This is the property the two CONSUMER hooks
# depend on, and it is independent of whether a warning was printed — which is
# the whole point: the failure this file was written for was invisible
# registration, not a missing warning. Asserting the file contents catches it;
# asserting stdout does not.
registered() { # <sid> -> YES|NO
  [ -f "$REG" ] || { printf 'NO'; return; }
  if REG_P="$REG" SID="$1" "$PY" -X utf8 -c "
import json, os, sys
try:
    d = json.load(open(os.environ['REG_P'], encoding='utf-8'))
except Exception:
    sys.exit(1)
sys.exit(0 if os.environ['SID'] in d else 1)
"; then printf 'YES'; else printf 'NO'; fi
}
# Write a peer entry directly, with a heartbeat <age> seconds in the past. Going
# through the file rather than a second hook run is what makes the TIME axis
# testable at all — otherwise a stale entry needs a 30-minute wait.
seed_peer() { # <sid> <age_seconds> [repos_json]
  REG_P="$REG" SID="$1" AGE="$2" REPOS="${3:-{\}}" "$PY" -X utf8 -c "
import json, os, time
p = os.environ['REG_P']
try:
    d = json.load(open(p, encoding='utf-8'))
except Exception:
    d = {}
now = int(time.time())
d[os.environ['SID']] = {'started': now, 'heartbeat': now - int(os.environ['AGE']),
                        'cwd': 'C:/elsewhere', 'repos': json.loads(os.environ['REPOS'])}
json.dump(d, open(p, 'w', encoding='utf-8'))
"
}
count_entries() {
  [ -f "$REG" ] || { printf '0'; return; }
  REG_P="$REG" "$PY" -X utf8 -c "
import json, os
try: print(len(json.load(open(os.environ['REG_P'], encoding='utf-8'))))
except Exception: print('ERR')
"
}

echo "A. register — the base pair"
rm -f "$REG"
out="$(run register "$(payload sessA)")"
check "A1 first session alone -> quiet" QUIET "$(verdict "$out")"
check "A2 ...but it IS in the registry (the part consumers read)" YES "$(registered sessA)"
# A2 is the case that matters most in this file. A1's silence is correct AND is
# exactly what an unregistered session produces, so without A2 the suite cannot
# tell "no peers to warn about" from "never wrote anything."

rm -f "$REG"
seed_peer peerX 60
out="$(run register "$(payload sessA)")"
check "A3 a live peer present -> warns" WARNED "$(verdict "$out")"
check "A4 ...names the peer by its id prefix" YES \
  "$(printf '%s' "$out" | grep -q 'peerX' && echo YES || echo NO)"
check "A5 ...and tells the agent to take a worktree" YES \
  "$(printf '%s' "$out" | grep -q 'worktree add' && echo YES || echo NO)"
check "A6 ...and self is registered alongside the peer" YES "$(registered sessA)"

rm -f "$REG"; seed_peer peerX 60
printf '%s' "$(payload sessA)" | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" register >/dev/null 2>&1
check "A7 exit status is 0 when it warns" 0 $?

echo
echo "R. the repos annotation — what makes the warning actionable"
# The peer's active sub-repos are filled in by worktree-guard.sh and are the only
# thing that tells the agent WHICH tree is contended. A warning without them
# names a session and no reason to care, which reads as noise.
rm -f "$REG"
seed_peer peerY 60 '{"D:/proj/alpha": '"$(date +%s)"', "D:/proj/beta": '"$(date +%s)"'}'
out="$(run register "$(payload sessA)")"
check "R1 peer's active repos are named" YES \
  "$(printf '%s' "$out" | grep -q 'alpha' && echo YES || echo NO)"
check "R2 ...all of them, not just the first" YES \
  "$(printf '%s' "$out" | grep -q 'beta' && echo YES || echo NO)"
# R3: a repo the peer touched long ago is NOT current activity. Listing it would
# send the agent to worktree a tree nobody is in.
rm -f "$REG"
seed_peer peerY 60 '{"D:/proj/alpha": 1}'
out="$(run register "$(payload sessA)")"
check "R3 a stale repo touch is not listed as active" NO \
  "$(printf '%s' "$out" | grep -q 'active in' && echo YES || echo NO)"
check "R4 ...but the peer is still warned about (control for R3)" WARNED "$(verdict "$out")"

echo
echo "T. staleness — the TIME axis, and the reason a crash does not warn forever"
# SessionEnd deregisters, but a crash or kill never fires it. The staleness prune
# is the backstop, and it is unobservable without moving the clock.
rm -f "$REG"
seed_peer peerStale 100000            # far beyond the 1800s default
check "T1 a long-dead peer is not warned about" QUIET "$(verdict "$(run register "$(payload sessA)")")"
check "T2 ...and is pruned from the registry entirely" NO "$(registered peerStale)"
# T3 is the paired control for T1/T2 — identical entry, heartbeat inside the
# window. Without it, T1's silence is equally consistent with a hook that never
# warns about anything.
rm -f "$REG"
seed_peer peerFresh 60
check "T3 an identical but fresh peer IS warned about (control)" WARNED \
  "$(verdict "$(run register "$(payload sessA)")")"

# T4/T5: the threshold is configurable via HOOK_SESSION_STALE_SECS, which is
# also how this block avoids hardcoding a dependence on the 1800s default.
# Holding the entry constant and moving only the threshold isolates the axis.
rm -f "$REG"; seed_peer peerEdge 300
check "T4 peer inside a widened window -> warns" WARNED \
  "$(verdict "$(run register "$(payload sessA)" HOOK_SESSION_STALE_SECS=600)")"
rm -f "$REG"; seed_peer peerEdge 300
check "T5 same peer, narrowed window -> quiet" QUIET \
  "$(verdict "$(run register "$(payload sessA)" HOOK_SESSION_STALE_SECS=100)")"

echo
echo "I. session identity — the axis that produced a silent unregistration"
# The env fallback used to read the bare CLAUDE_SESSION_ID, which this build
# never sets. Any payload without a session_id therefore hit the anonymous exit
# and the session went UNREGISTERED — invisible to worktree-guard and read as
# dead by the liveness check in the other consumer.
#
# Every other case in this file supplies session_id in the payload, so every one
# of them passes under that bug. This is the axis they cannot see.
rm -f "$REG"
run register '{"cwd":"'"$FIX"'"}' CLAUDE_CODE_SESSION_ID=envsess >/dev/null
check "I1 no session_id in payload, CLAUDE_CODE_SESSION_ID set -> registered" YES "$(registered envsess)"
# I2: the legacy name still works, so a different or older build is not silently
# dropped. It is a fallback, not the primary — I3 pins the precedence.
rm -f "$REG"
run register '{"cwd":"'"$FIX"'"}' CLAUDE_SESSION_ID=legacysess >/dev/null
check "I2 legacy CLAUDE_SESSION_ID still honoured as a fallback" YES "$(registered legacysess)"
rm -f "$REG"
run register '{"cwd":"'"$FIX"'"}' CLAUDE_CODE_SESSION_ID=primary CLAUDE_SESSION_ID=legacy >/dev/null
check "I3 CLAUDE_CODE_SESSION_ID wins when both are set" YES "$(registered primary)"
check "I4 ...and the legacy value is not also registered" NO "$(registered legacy)"
# I5: payload beats env. The payload is the authoritative identity; a regression
# that preferred the env var would merge distinct sessions into one entry.
rm -f "$REG"
run register "$(payload frompayload)" CLAUDE_CODE_SESSION_ID=fromenv >/dev/null
check "I5 payload session_id outranks the env var" YES "$(registered frompayload)"
# I6: genuinely anonymous. Must fail open — exit 0, no entry, no noise. Tracking
# an anonymous session would collide every such session into one bogus entry.
rm -f "$REG"
out="$(run register '{"cwd":"'"$FIX"'"}')"
check "I6 no id anywhere -> nothing registered" 0 "$(count_entries)"
check "I7 ...and it stays quiet" QUIET "$(verdict "$out")"
printf '%s' '{}' | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" register >/dev/null 2>&1
check "I8 ...and exits 0 (fail open — never block a session start)" 0 $?

echo
echo "M. modes — heartbeat and deregister"
rm -f "$REG"
seed_peer peerZ 60
out="$(run heartbeat "$(payload sessA)")"
check "M1 heartbeat registers self" YES "$(registered sessA)"
# M2 is the mode contract: heartbeat fires on EVERY assistant turn, so a warning
# from it would repeat the whole worktree banner on every single turn. Only
# `register` (SessionStart) may speak.
check "M2 heartbeat is silent even with a live peer" QUIET "$(verdict "$out")"

# M3: heartbeat must MOVE the timestamp, not merely leave the entry present. A
# regression that upserts without bumping it lets a live session age out and be
# pruned mid-work — at which point its peers stop being warned about it.
rm -f "$REG"
seed_peer sessA 1200                       # own entry, aging but not yet stale
run heartbeat "$(payload sessA)" >/dev/null
fresh="$(REG_P="$REG" "$PY" -X utf8 -c "
import json, os, time
d = json.load(open(os.environ['REG_P'], encoding='utf-8'))
print('YES' if time.time() - d['sessA']['heartbeat'] < 60 else 'NO')
")"
check "M3 heartbeat advances the timestamp, not just the entry" YES "$fresh"

rm -f "$REG"
seed_peer peerZ 60
run register "$(payload sessA)" >/dev/null
run deregister "$(payload sessA)" >/dev/null
check "M4 deregister removes self" NO "$(registered sessA)"
check "M5 ...and leaves the peer alone" YES "$(registered peerZ)"
out="$(run deregister "$(payload sessA)")"
check "M6 deregister is silent" QUIET "$(verdict "$out")"
# M7: deregistering a session that was never registered is normal (a crash
# between SessionStart and SessionEnd) and must not error.
rm -f "$REG"
printf '%s' "$(payload ghost)" | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" deregister >/dev/null 2>&1
check "M7 deregistering an unknown session exits 0" 0 $?

echo
echo "F. degraded inputs — advisory, fail-open, never block a session start"
rm -f "$REG"
check "F1 empty payload -> quiet" QUIET "$(verdict "$(run register "")")"
err="$(run_err register "")"
if [ -z "$err" ]; then echo "  PASS  F2 empty payload emits nothing on stderr"; pass=$((pass+1))
else echo "  FAIL  F2 empty payload wrote to stderr: $err"; fail=$((fail+1)); fi
check "F3 unparseable payload -> quiet" QUIET "$(verdict "$(run register '{not json')")"
printf '%s' '{not json' | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash "$HOOK" register >/dev/null 2>&1
check "F4 ...and exits 0" 0 $?

# F5: a corrupt registry on disk. This file is written by concurrent sessions
# with last-writer-wins semantics, so a truncated read is a real possibility —
# and it must not take down every future session start. Recovering by treating it
# as empty is the documented posture; assert it rather than assume it.
printf 'garbage not json' > "$REG"
run register "$(payload sessA)" >/dev/null
check "F5 corrupt registry recovers rather than wedging" YES "$(registered sessA)"

# F6: the registry write is atomic (temp + os.replace), so no .tmp shard may be
# left behind. A leaked shard accumulates in a gitignored directory forever and,
# worse, means a crashed write could leave the real file absent.
rm -f "$REG"
run register "$(payload sessA)" >/dev/null
shards="$(find "$FIX" -name '.session-registry.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
check "F6 no temp shard is left behind (atomic write)" 0 "$shards"

echo
echo "H. mirror integrity"
if cmp -s "$REAL_HOOK" "$HOOK"; then
  echo "  PASS  H1 mirrored hook is byte-identical to the shipped hook"; pass=$((pass+1))
else
  echo "  FAIL  H1 mirrored hook has drifted from hooks/session-registry.sh"; fail=$((fail+1))
fi
# H2: the fixture registry must be the ONLY one this suite touched. If REG
# resolution ever moves, these cases would silently mutate the live registry
# tracking every other session on this machine — a far worse outcome than a
# failing test, and one nothing else would report.
if [ -f "$REG" ]; then
  echo "  PASS  H2 the registry under test is the fixture, not the machine's live one"; pass=$((pass+1))
else
  echo "  FAIL  H2 no fixture registry was created — REG resolved somewhere else"; fail=$((fail+1))
fi

echo
echo "Z. fixture root stays outside the checkout under test"
# Structural pin, and the reason this arrangement sticks. The note at the top of
# the file explains WHY the root is outside the repo; a note is a request.
# Without an assertion the next person to "simplify" it back to
# $HOOK_DIR/.<name>_test_fixtures reintroduces the leak silently, which in this
# repo has now happened twice.
# rev-parse rather than a `.git` directory test, so it stays correct in a worktree
# — where `.git` is a FILE, and where a `[ -d .git ]` walk would answer "not a
# repo" and pass this case vacuously.
z_scope="$(fixture_root_scope "$HOOK_DIR" "$FIX")"
if [ "$z_scope" = "outside" ]; then
  echo "  PASS  Z1 fixture root is outside the checkout under test"; pass=$((pass+1))
else
  echo "  FAIL  Z1 fixture root is back INSIDE the checkout ($FIX) — the hook can"
  echo "        now reach the developer's real repo state from a fixture path."
  fail=$((fail+1))
fi

echo "----------------------------------------"
echo "passed: $pass   failed: $fail   skipped: $skip"
[ "$fail" -eq 0 ] || exit 1
