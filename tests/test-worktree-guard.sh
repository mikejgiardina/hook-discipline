#!/bin/bash
# Behavioral tests for hooks/worktree-guard.sh — the dirty-tree / parallel-session guard.
#
# === What it protects ===
# Pulling, merging or rebasing onto uncommitted work is how two agent sessions
# sharing a working tree commit onto each other's branches and split a thread
# mid-commit. That happened here once and cost a day. The guard interrupts
# exactly that moment.
#
# === Three verdict states, not two — which is why the matcher differs ===
# Every other gate here is deny-or-silent. This one emits **ask** by default and
# **deny** only under HOOK_WORKTREE_HARDBLOCK. A matcher that only looks for
# "deny" reads every ask as an allow and the suite passes while the guard does
# nothing — the same class as the compact-vs-spaced deny bug a sibling suite in
# this repo shipped, one state further out.
#
# === It is FAIL OPEN, unlike the disclosure gates ===
# No python, unparseable payload, not a work tree, `git status` unreadable — all
# exit 0 silently. Correct: this guards against a *risk*, not an irreversible
# act, and a guard that blocks `git pull` on a toolchain hiccup is one you
# disable. So the hazard here is a FALSE ask/deny, and the load-bearing cases are
# the recovery sub-commands (R1-R4): `--abort/--continue/--quit/--skip` are how
# you REACH a clean tree, so guarding them would trap the operator inside the
# conflict state with no exit. That is worse than not guarding at all.
#
# === Registry side effect is load-bearing and easy to lose silently ===
# Before deciding anything, the hook records this session's per-repo activity in
# .session-registry.json. That file is what the SessionStart guard reads to warn
# "N other live sessions share this workspace" — the warning that surfaced three
# real collisions in a single day. If the touch silently stops, no verdict
# changes and nothing fails; the cross-session warning just quietly goes blind.
# Case S1 pins it.
#
# === Paired positive control ===
# Known-bad must fire AND known-good must stay silent, same run. Especially
# necessary for a fail-open hook: an all-silent suite is indistinguishable from
# one where the hook never ran.
#
# Hermetic: throwaway repos, no network. Registry writes land in the fixture
# tree, never the real one (the hook resolves it from its own location, and this
# runs a COPY).
# Run: bash tests/test-worktree-guard.sh

set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_DIR="$(cd "$TESTS_DIR/../hooks" && pwd)"
LIB_DIR="$(cd "$TESTS_DIR/../lib" && pwd)"
SRC="$HOOK_DIR/worktree-guard.sh"
[ -f "$SRC" ] || { echo "FATAL: $SRC not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required"; exit 1; }

# Fixtures live OUTSIDE any repo, and under a DRIVE-FORM path on Windows. Two
# separate fixture bugs are baked into that sentence, and the shared helper is
# what fixes both:
#
#   1. Nesting them under the checkout made the "not a git work tree" case
#      resolve to this repo's own toplevel — dirty while the test is being
#      written, so it asked instead of staying silent. A fixture that inherits a
#      surrounding repo tests the surroundings, not the hook.
#   2. A bare `mktemp -d` lands in /tmp, which on Git-Bash is an MSYS *mount
#      point*, not a drive path. The path normaliser converts /d/... and
#      deliberately leaves /tmp/... alone, so /tmp fixtures could never exercise
#      the very case they were written for — they just looked broken. Real
#      payloads name repos in drive form, so the fixture must too.
#
# fixture_root_init returns a drive-lettered MSYS path on Windows and an
# ordinary temp path elsewhere, outside any checkout in both cases.
. "$TESTS_DIR/lib/fixture-root.sh"
fixture_root_init wtg
mkdir -p "$FIX/hooks" "$FIX/lib"

# Run a COPY so the registry the hook touches (<its own dir>/.session-registry.json)
# lands in the fixture tree. Writing the real one would corrupt live cross-session
# state — the very thing this hook exists to keep honest.
HOOK="$FIX/hooks/worktree-guard.sh"
cp "$SRC" "$HOOK"
# The mirrored hook sources ../lib/resolve-python.sh relative to its own
# location. Without this copy the source fails, resolve_python is undefined, PY
# comes back empty and the hook takes its no-python branch -- which for the
# advisory hooks is a SILENT exit 0. Every assertion then passes-by-not-running,
# which is the exact shape this whole suite exists to rule out.
cp "$LIB_DIR/resolve-python.sh" "$FIX/lib/"
# lib/cmdparse.py supplies the MSYS path normaliser the W block below exercises.
# Mirroring it is not bookkeeping — omit it and every W case fails identically
# with and without a working normaliser, because a missing module and a broken
# conversion both end in the same silent exit. That indistinguishability is what
# this suite exists to rule out, so the omission is worth stating rather than
# leaving as an obvious `cp`.
#
# The X block at the bottom uses a SECOND mirror that deliberately lacks the
# module, which is what turns "the module is missing" from an untested accident
# into an asserted behaviour.
cp "$LIB_DIR/cmdparse.py" "$FIX/lib/"
# lib/jsonstate.py carries the registry lock and load/save. Without it the hook
# announces the missing module and skips the registry touch, so S1/S2 would fail
# for a reason unrelated to their subject.
cp "$LIB_DIR/jsonstate.py" "$FIX/lib/"
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


# THREE states. Anything that collapses ask into allow makes this suite lie.
verdict() {
  case "$1" in
    *'"permissionDecision"'*'"deny"'*)  printf 'DENY' ;;
    *'"permissionDecision"'*'"ask"'*)   printf 'ASK'  ;;
    *)                                  printf 'SILENT' ;;
  esac
}
payload() { # <cmd> [cwd] [session_id]
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s","session_id":"%s"}' \
    "$1" "${2:-}" "${3:-testsession}"
}
check() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1 — expected $2, got $3"; fail=$((fail+1)); fi
}
run() { ( cd "${2:-$FIX}" 2>/dev/null || cd /; printf '%s' "$1" | bash "$HOOK" 2>/dev/null ); }

mk_repo() { # <name> <dirty:0|1>  -> echoes the path
  local d="$FIX/$1"
  mkdir -p "$d"; git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  echo base > "$d/README.md"; git -C "$d" add README.md >/dev/null 2>&1
  git -C "$d" commit -qm base >/dev/null 2>&1
  [ "$2" = "1" ] && echo uncommitted >> "$d/README.md"
  printf '%s' "$d"
}

# Native Windows form (D:/...). The hook's python is a NATIVE Windows
# interpreter and the runtime hands it a native `cwd`, so this is the shape the
# guard is actually built against. MSYS paths get their own case group below —
# see the W-block, where they are NOT equivalent.
W() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

echo "worktree-guard.sh"

if bash -n "$SRC" 2>/dev/null; then echo "  PASS  syntax"; pass=$((pass+1))
else echo "  FAIL  syntax"; exit 1; fi

DIRTY="$(mk_repo dirty 1)"; CLEAN="$(mk_repo clean 0)"; mkdir -p "$FIX/nogit"
DIRTY_W="$(W "$DIRTY")"; CLEAN_W="$(W "$CLEAN")"; NOGIT_W="$(W "$FIX/nogit")"

# --- A. the ask path — known-bad must FIRE (the positive control) -----------
for op in pull merge rebase; do
  check "A git $op on a DIRTY tree -> ask" ASK \
    "$(verdict "$(run "$(payload "git -C $DIRTY_W $op")")")"
done
check "A a merge command on a DIRTY tree -> ask" ASK \
  "$(verdict "$(run "$(payload 'gh pr merge 1 --squash' "$DIRTY_W")")")"

# `git -C <dir> pull` is called out in the hook: the naive `git\s+(pull|merge)`
# regex misses it, and it is the most common form in real transcripts.
check "A global options tolerated (git -c k=v -C dir merge) -> ask" ASK \
  "$(verdict "$(run "$(payload "git -c user.name=x -C $DIRTY_W merge")")")"

# --- R. RECOVERY sub-commands must NEVER be guarded (load-bearing) ----------
# These are how you reach a clean tree. Guarding them traps the operator inside
# the conflict state with no exit — worse than not guarding at all.
for sub in abort continue quit skip; do
  check "R git rebase --$sub on a DIRTY tree -> silent" SILENT \
    "$(verdict "$(run "$(payload "git -C $DIRTY_W rebase --$sub")")")"
done

# --- B. known-good must stay SILENT -----------------------------------------
check "B clean tree + pull -> silent" SILENT \
  "$(verdict "$(run "$(payload "git -C $CLEAN_W pull")")")"
check "B non-mutating op on a dirty tree (git status) -> silent" SILENT \
  "$(verdict "$(run "$(payload "git -C $DIRTY_W status")")")"
check "B non-mutating op on a dirty tree (git log) -> silent" SILENT \
  "$(verdict "$(run "$(payload "git -C $DIRTY_W log --oneline")")")"
check "B command mentioning no VCS verb at all -> silent" SILENT \
  "$(verdict "$(run "$(payload 'ls -la' "$DIRTY_W")")")"
check "B target is not a git work tree -> silent" SILENT \
  "$(verdict "$(run "$(payload "git -C $NOGIT_W pull")")")"

# --- C. hardblock escalates ask -> deny -------------------------------------
check "C HOOK_WORKTREE_HARDBLOCK=1 -> deny" DENY \
  "$(verdict "$(cd "$FIX" && printf '%s' "$(payload "git -C $DIRTY_W pull")" | HOOK_WORKTREE_HARDBLOCK=1 bash "$HOOK" 2>/dev/null)")"
check "C hardblock does NOT fire on a clean tree" SILENT \
  "$(verdict "$(cd "$FIX" && printf '%s' "$(payload "git -C $CLEAN_W pull")" | HOOK_WORKTREE_HARDBLOCK=1 bash "$HOOK" 2>/dev/null)")"

# --- D. FAIL OPEN on anything unevaluable (inverted vs the disclosure gates) -
check "D unparseable payload -> silent" SILENT "$(verdict "$(run 'not json at all, but mentions git')")"
check "D empty payload -> silent" SILENT "$(verdict "$(run '')")"
if [ -x /usr/bin/cat ] && ! PATH=/usr/bin command -v python3 >/dev/null 2>&1 \
                       && ! PATH=/usr/bin command -v python >/dev/null 2>&1; then
  check "D python absent -> silent (fail open)" SILENT \
    "$(verdict "$(cd "$FIX" && printf '%s' "$(payload "git -C $DIRTY_W pull")" | PATH=/usr/bin bash "$HOOK" 2>/dev/null)")"
else
  echo "  SKIP  D python-absent (no python-free PATH with a working cat here)"; skip=$((skip+1))
fi

# --- E. resolution axes + cwd invariance ------------------------------------
check "E resolution via leading cd -> ask" ASK \
  "$(verdict "$(run "$(payload "cd $DIRTY_W && git pull")")")"
check "E resolution via payload cwd -> ask" ASK \
  "$(verdict "$(run "$(payload 'git pull' "$DIRTY_W")" "$DIRTY_W")")"
# The verdict must follow the RESOLVED target, not wherever the hook happens to
# run. A regression to cwd-only resolution passes the two above and fails this.
check "E dirty target still asks while running inside a CLEAN repo" ASK \
  "$(verdict "$(run "$(payload "git -C $DIRTY_W pull")" "$CLEAN_W")")"

# --- S. the registry side effect (silent to lose, load-bearing to keep) -----
# .session-registry.json is what the SessionStart guard reads to warn about other
# live sessions. If this touch stops, no verdict changes and nothing fails; the
# cross-session warning just goes blind.
rm -f "$REG"
run "$(payload "git -C $CLEAN_W status" "$CLEAN_W" "sess-abc123")" >/dev/null 2>&1
if [ -f "$REG" ] && grep -q 'sess-abc123' "$REG" 2>/dev/null && grep -q 'heartbeat' "$REG" 2>/dev/null; then
  echo "  PASS  S1 session + heartbeat recorded in the registry"; pass=$((pass+1))
else
  echo "  FAIL  S1 registry not written — the cross-session warning would go blind"; fail=$((fail+1))
fi
# The expected key is asked of GIT, not assembled from the fixture path.
#
# The hook records `git rev-parse --show-toplevel`, and that is a CANONICAL path:
# git resolves symlinks and expands short names. A fixture path does not
# necessarily survive that round trip, and where it does not, comparing the two
# literally tests the platform's path spelling rather than whether the repo was
# recorded at all.
#
# Two real instances, neither reproducible on Linux, which is why this passed
# locally and on one CI leg while failing on the other two:
#   macOS   — `mktemp -d` yields /var/folders/..., and /var is a symlink to
#             /private/var, so git reports /private/var/folders/...
#   Windows — a runner temp path can carry an 8.3 short name (RUNNER~1) while
#             git reports the long form.
EXPECT_TOP="$(git -C "$CLEAN" rev-parse --show-toplevel 2>/dev/null | tr -d '\r')"
if [ -z "$EXPECT_TOP" ]; then
  echo "  FAIL  S2 could not resolve the fixture repo's toplevel — assertion would be vacuous"; fail=$((fail+1))
elif [ -f "$REG" ] && EXPECT_TOP="$EXPECT_TOP" "$(command -v python3 || command -v python)" -X utf8 -c "
import json,os,sys
want=os.environ['EXPECT_TOP']
d=json.load(open(sys.argv[1],encoding='utf-8'))
keys=[k for v in d.values() if isinstance(v,dict) for k in (v.get('repos') or {})]
# Compare case-insensitively with separators normalised: Windows paths are
# case-insensitive and git may report a different drive-letter case than the
# shell used. Falling back to a basename match would make the assertion pass for
# any repo at all, so it is deliberately not done.
n=lambda p: p.replace('\\\\','/').rstrip('/').lower()
sys.exit(0 if any(n(k)==n(want) for k in keys) else 1)
" "$REG" 2>/dev/null; then
  echo "  PASS  S2 the touched repo is recorded per-session"; pass=$((pass+1))
else
  echo "  FAIL  S2 repo path missing from the registry entry (wanted $EXPECT_TOP)"; fail=$((fail+1))
fi

# --- L. the registry lock and a damaged registry (#4) ------------------------
# The registry touch runs under the registry lockfile. A held lock makes the
# touch wait briefly and skip, and it must never change the verdict: this guard
# is advisory, and a busy registry is not a reason to block or to allow anything
# it would not otherwise. L5 is the control for L2: the same command with the
# lock free does write.
rm -f "$REG" "$REG.lock"
printf '4242 1700000000\n' > "$REG.lock"
out="$( cd "$FIX" && printf '%s' "$(payload "git -C $CLEAN_W status" "$CLEAN_W" "sess-locked")" | bash "$HOOK" 2>/dev/null )"
rc=$?
check "L1 held registry lock: git status is still allowed" "SILENT/0" "$(verdict "$out")/$rc"
check "L2 ...and the registry is not written" NO \
  "$(grep -q 'sess-locked' "$REG" 2>/dev/null && echo YES || echo NO)"
check "L3 ...and the holder's lockfile is left in place" '4242 1700000000' "$(cat "$REG.lock" 2>/dev/null)"
check "L4 held registry lock: a dirty pull still asks (verdict unchanged)" ASK \
  "$(verdict "$(run "$(payload "git -C $DIRTY_W pull" "" "sess-locked")")")"
rm -f "$REG.lock"
run "$(payload "git -C $CLEAN_W status" "$CLEAN_W" "sess-locked")" >/dev/null 2>&1
check "L5 lock free: the same command records the session (control for L2)" YES \
  "$(grep -q 'sess-locked' "$REG" 2>/dev/null && echo YES || echo NO)"

# L6/L7: a registry that cannot be parsed is left exactly as it is. Overwriting
# it with this session alone is how every peer used to vanish.
printf 'garbage {"peer": not json' > "$REG"
cp "$REG" "$FIX/expected-corrupt"
err="$( cd "$FIX" && printf '%s' "$(payload "git -C $CLEAN_W status" "$CLEAN_W" "sess-c")" | bash "$HOOK" 2>&1 >/dev/null )"
if cmp -s "$FIX/expected-corrupt" "$REG"; then
  echo "  PASS  L6 an unreadable registry is not overwritten"; pass=$((pass+1))
else
  echo "  FAIL  L6 the unreadable registry was overwritten"; fail=$((fail+1))
fi
check "L7 ...and the hook says so on stderr" YES \
  "$(printf '%s' "$err" | grep -q 'unreadable' && echo YES || echo NO)"
rm -f "$REG" "$REG.lock"

# --- F. payload shape --------------------------------------------------------
PY="$(command -v python3 || command -v python || true)"
if [ -n "$PY" ]; then
  out="$(run "$(payload "git -C $DIRTY_W pull")")"
  if printf '%s' "$out" | "$PY" -X utf8 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d['hookSpecificOutput']['permissionDecision']=='ask' else 1)" 2>/dev/null; then
    echo "  PASS  F1 ask payload is well-formed JSON"; pass=$((pass+1))
  else
    echo "  FAIL  F1 ask payload is not parseable JSON:"; echo "$out" | sed 's/^/        /'; fail=$((fail+1))
  fi
else
  echo "  SKIP  F1 JSON well-formedness (no python)"; skip=$((skip+1))
fi

# --- W. MSYS path forms must not be invisible to the guard ------------------
# Every case above uses the native Windows form, because that is what the
# runtime hands the hook as `cwd`. But a COMMAND names its repo in whatever form
# the operator typed, and on Git-Bash that is overwhelmingly bash-style:
# `git -C /d/proj/repo pull`.
#
# resolve_target() passes that through verbatim to a NATIVE Windows python:
#     git -C /d/proj/repo  -> rc=128 "cannot change to"
#     git -C D:/proj/repo  -> rc=0
# so the hook takes its "not a git work tree -> fail open" branch and says
# nothing. Right branch for a real non-repo, wrong one here: the target IS a
# repo, only the spelling is unreadable.
#
# Two silent losses. The early return also skips the registry touch, so a session
# working via `-C` with bash paths never appears in .session-registry.json and is
# invisible to every other session's collision warning.
#
# Third instance of a family another guard in this layer had already hit. These
# are HARD assertions and not a known-gap block — a gap line would let a
# regression read as intentional.
#
# They are also the only coverage the inline to_native_path() has. That is a
# deliberate trade: the normaliser used to live in a shared module the hook
# imported, which made it unit-testable and made the import failure a silent
# no-op. Behavioural coverage of a function that cannot vanish beats unit
# coverage of one that can.
#
# Skipped where the fixture root is not drive-form, since there the paths are
# already native and the case proves nothing. Note the skip is not a gap in the
# platform guard: `/d/foo` is an ordinary absolute path on macOS and Linux, and a
# normaliser that rewrote it there would invent a bug — the B cases above run
# against exactly those ordinary paths and would go red if it did.
case "$DIRTY" in
  /[A-Za-z]/*)
    for form in "git -C $DIRTY pull" "cd $DIRTY && git pull"; do
      check "W MSYS path form still asks: ${form%% *} ${form#* }" ASK \
        "$(verdict "$(run "$(payload "$form")")")"
    done
    # The registry touch happens before the verdict, so the MSYS blindness cost
    # two things: the ask AND the session's visibility to its peers.
    rm -f "$REG"
    run "$(payload "git -C $DIRTY status" "" "sess-msys")" >/dev/null 2>&1
    if grep -q 'sess-msys' "$REG" 2>/dev/null; then
      echo "  PASS  W MSYS-path session is recorded in the registry"; pass=$((pass+1))
    else
      echo "  FAIL  W MSYS-path session absent from the registry — invisible to peers"; fail=$((fail+1))
    fi
    ;;
  *)
    # ONE SKIP LINE PER SKIPPED ASSERTION, not one for the block.
    #
    # This branch stands in for three assertions. Emitting a single SKIP for all
    # of them makes the suite's total silently platform-dependent: 34 on Windows
    # where they run, 32 elsewhere where one line replaces three. The runner's
    # floor check treats a bare SKIP as exactly one case — deliberately, so that
    # a block-level skip standing in for many cannot balance the books.
    #
    # Per-case skips keep `assertions + skips` invariant across platforms, which
    # is what makes a drop in that sum mean something.
    echo "  SKIP  W MSYS path form (git -C) — fixture root is not drive-form"; skip=$((skip+1))
    echo "  SKIP  W MSYS path form (leading cd) — fixture root is not drive-form"; skip=$((skip+1))
    echo "  SKIP  W MSYS-path session recorded — fixture root is not drive-form"; skip=$((skip+1))
    ;;
esac

# --- X. the missing-dependency branch must be LOUD --------------------------
# This is the block the whole repository is arguing for, so it is worth being
# precise about what it asserts.
#
# The hook imports its path normaliser from lib/cmdparse.py. If that import
# fails, the hook does NOT stop working — it keeps parsing payloads, keeps
# reaching verdicts, and is simply blind to one class of command. Every verdict
# it returns is still a verdict. Nothing errors. Nothing exits non-zero.
#
# That is fail-SILENT, and it is a different decision from fail-open. Fail-open
# says "without a verdict, allow". Fail-silent says "having had no verdict, say
# nothing about it". This hook is deliberately fail-open; it must not be
# fail-silent, because a degraded guard that announces nothing is indistinguishable
# from a healthy one and will therefore never be repaired.
#
# X1 is the assertion. X0 and X3 are what stop it being vacuous: X0 proves the
# stripped mirror genuinely lacks the module (otherwise X1 could pass because
# some unrelated stderr appeared), and X3 proves the equipped mirror stays quiet
# (otherwise X1 could pass because the hook warns unconditionally).
echo
echo "X. the missing-dependency branch"
BARE="$FIX/bare"
mkdir -p "$BARE/hooks" "$BARE/lib"
cp "$SRC" "$BARE/hooks/worktree-guard.sh"
cp "$LIB_DIR/resolve-python.sh" "$BARE/lib/"
# cmdparse.py deliberately NOT copied.

if [ ! -f "$BARE/lib/cmdparse.py" ]; then
  echo "  PASS  X0 the stripped mirror genuinely lacks cmdparse (premise of X1)"; pass=$((pass+1))
else
  echo "  FAIL  X0 stripped mirror still has cmdparse — X1 would be vacuous"; fail=$((fail+1))
fi

X_ERR="$(printf '{"tool_name":"Bash","tool_input":{"command":"git status"},"cwd":"%s","session_id":"x1"}' "$FIX" \
         | bash "$BARE/hooks/worktree-guard.sh" 2>&1 >/dev/null)"
X_RC=$?
if printf '%s' "$X_ERR" | grep -q 'cmdparse'; then
  echo "  PASS  X1 a missing dependency is announced on stderr, not swallowed"; pass=$((pass+1))
else
  echo "  FAIL  X1 missing cmdparse degraded SILENTLY — the guard stops seeing"; fail=$((fail+1))
  echo "        half its traffic and nothing says so. stderr was: '$X_ERR'"
fi

if [ "$X_RC" -eq 0 ]; then
  echo "  PASS  X2 ...and still exits 0 (loud, not fatal — advisory stays advisory)"; pass=$((pass+1))
else
  echo "  FAIL  X2 degraded path exited $X_RC — an advisory hook must not block"; fail=$((fail+1))
fi

Y_ERR="$(printf '{"tool_name":"Bash","tool_input":{"command":"git status"},"cwd":"%s","session_id":"x3"}' "$FIX" \
         | bash "$HOOK" 2>&1 >/dev/null)"
if printf '%s' "$Y_ERR" | grep -q 'cmdparse'; then
  echo "  FAIL  X3 the EQUIPPED mirror also warns — X1 proves nothing"; fail=$((fail+1))
else
  echo "  PASS  X3 the equipped mirror stays quiet (control for X1)"; pass=$((pass+1))
fi

echo "----------------------------------------"
echo "passed: $pass   failed: $fail   skipped: $skip"
[ "$fail" -eq 0 ] || exit 1
