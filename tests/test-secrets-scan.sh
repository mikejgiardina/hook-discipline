#!/bin/bash
# Behavioral tests for hooks/secrets-scan.sh — the staged-secret commit block.
#
# === Why this file exists ===
# secrets-scan is the highest-blast-radius hook in the layer: a silent failure
# puts credentials into git history, where the only remedy is a filter-repo
# rewrite plus a force-push that still leaves server-side residual refs. It has
# been a silent no-op once already — a bite-test found it jq-dependent on a
# jq-free machine, so every jq call errored, the `|| true` in the wiring
# swallowed it, and the hook FAILED OPEN, allowing every commit including ones
# staging secrets. It was hardened the same day and then had no regression test
# at all. This is that test.
#
# === A test only sees the axis it varies ===
# Another gate in this layer HAD a good test — built from the real commits of
# the incident it was written for, not from fixtures — and still shipped a
# destructive false positive, because every case exercised a target repo from
# inside a checkout of that same repo. cwd and the target coincided, so the
# hook's cwd-dependence was structurally invisible to its own suite.
#
# secrets-scan's implicit axis is TARGET REPO RESOLUTION. It is wired to run
# from a workspace root that is not itself a git repo, so a bare
# `git diff --cached` would see nothing and allow everything. It therefore
# resolves the target three different ways — `git -C <dir>`, a leading
# `cd <dir> &&`, and the payload cwd — and a regression in any one of them fails
# OPEN and silent. So: every resolution form is exercised (cases 5-7), and the
# load-bearing cases are 8 and 9, which hold the staged secret constant while
# moving the HOOK'S OWN cwd to an unrelated clean repo and to a non-repo
# directory. A regression to a bare `git diff --cached` passes 5-7 and goes red
# on 8-9.
#
# Hermetic: builds throwaway git repos, no network, no external CLI, no
# dependence on any checkout existing on the machine.
# Run: bash tests/test-secrets-scan.sh

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
HOOK="$HOOK_DIR/secrets-scan.sh"
[ -f "$HOOK" ] || { echo "FATAL: $HOOK not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required"; exit 1; }

# === Fixture root: outside the checkout, and here that is LOAD-BEARING ========
# Several suites in this repo once wrote their fixtures INSIDE the checkout
# under test. This is the one where that was LIVE rather than latent, and it is
# the worst of them because secrets-scan is fail-closed and blocking.
#
# secrets-scan runs `git -C "$TARGET" rev-parse --is-inside-work-tree` and exits
# 0 if that fails. `git -C` is itself an upward parent walk: it does not require
# $TARGET to BE a repo root, only to sit somewhere under one. With the fixture
# root inside the checkout, `$FIX/nogit` — created with a bare `mkdir -p`,
# deliberately not a repo — was still inside this repo, so
# `--is-inside-work-tree` answered **true**, the early exit never fired, and
# case 14 went on to scan the DEVELOPER'S REAL STAGED INDEX.
#
# It passed anyway, because that index happened to be empty. That is the shape
# this whole suite exists to catch: an assertion reporting success having never
# reached its own subject. Verified in both directions while making the change —
# stage a file named `*.key` anywhere in the checkout and case 14 flipped to
# DENY, "proving" a regression in a hook that had not changed.
#
# Case 14N below is the paired control that makes this non-vacuous from now on.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/fixture-root.sh"
fixture_root_init secrets

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


# The deny matcher MUST tolerate whitespace: secrets-scan emits deny through TWO
# paths — a python-free `printf` (compact, `"permissionDecision":"deny"`) and
# `json.dumps` (spaced, `"permissionDecision": "deny"`). A matcher written for
# only the compact form reads every python-formatted deny as an ALLOW, which is
# a harness bug a sibling suite in this repo shipped for real.
verdict() {
  if printf '%s' "$1" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'DENY'
  else
    printf 'ALLOW'
  fi
}

# Payload as PreToolUse(Bash) delivers it: JSON on stdin, command nested at
# .tool_input.command. Built with printf; every path used here is MSYS-style
# with forward slashes, so no JSON escaping is needed.
payload() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "${2:-}"; }

run_hook() { # <cwd-to-run-from> <payload>
  ( cd "$1" 2>/dev/null || cd /; printf '%s' "$2" | bash "$HOOK" 2>&1 )
}

check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  PASS  $1"; pass=$((pass+1))
  else
    echo "  FAIL  $1 — expected $2, got $3"; fail=$((fail+1))
  fi
}

mk_repo() { # <path> ; a real repo with one commit so `diff --cached` is meaningful
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" config commit.gpgsign false
  echo base > "$d/README.md"
  git -C "$d" add README.md >/dev/null 2>&1
  git -C "$d" commit -qm base >/dev/null 2>&1
}

echo "secrets-scan.sh"

# --- 1. syntax --------------------------------------------------------------
if bash -n "$HOOK" 2>/dev/null; then echo "  PASS  syntax"; pass=$((pass+1))
else echo "  FAIL  syntax"; exit 1; fi

DIRTY="$FIX/dirty"; CLEAN="$FIX/clean"; NOGIT="$FIX/nogit"
mk_repo "$DIRTY"; mk_repo "$CLEAN"; mkdir -p "$NOGIT"
echo "SECRET=1" > "$DIRTY/.env.local"
git -C "$DIRTY" add -f .env.local >/dev/null 2>&1
echo ordinary > "$CLEAN/notes.md"
git -C "$CLEAN" add notes.md >/dev/null 2>&1

# --- 2-4. things that are not a commit must pass through untouched ----------
out="$(run_hook "$FIX" "$(payload 'ls -la' "$FIX")")"
check "non-commit command allowed" ALLOW "$(verdict "$out")"

out="$(printf '' | bash "$HOOK" 2>&1)"
check "empty payload allowed" ALLOW "$(verdict "$out")"

# Trips the raw "commit" pre-filter but is not a git commit -> NOTCOMMIT branch.
out="$(run_hook "$FIX" "$(payload 'echo remember to commit later' "$DIRTY")")"
check "commit-shaped-but-not-git allowed" ALLOW "$(verdict "$out")"

# --- 5-7. every target-resolution form must find the staged secret ----------
out="$(run_hook "$FIX" "$(payload "git -C $DIRTY commit -m x" "$FIX")")"
check "resolution via -C -> deny" DENY "$(verdict "$out")"

out="$(run_hook "$FIX" "$(payload "cd $DIRTY && git commit -m x" "$FIX")")"
check "resolution via leading cd -> deny" DENY "$(verdict "$out")"

out="$(run_hook "$DIRTY" "$(payload 'git commit -m x' "$DIRTY")")"
check "resolution via payload cwd -> deny" DENY "$(verdict "$out")"

# --- 8-9. the cwd-invariance cases ------------------------------------------
# Staged secret held constant in $DIRTY; only the directory the hook runs from
# moves. A regression to a bare `git diff --cached` would consult the wrong repo
# (or no repo) and allow the commit — silently, which is the whole hazard.
out="$(run_hook "$CLEAN" "$(payload "git -C $DIRTY commit -m x" "$FIX")")"
check "denies while running inside an UNRELATED clean repo" DENY "$(verdict "$out")"

out="$(run_hook "$NOGIT" "$(payload "git -C $DIRTY commit -m x" "$FIX")")"
check "denies while running from a NON-repo dir" DENY "$(verdict "$out")"

# --- 10. no false positive on an ordinary staged file -----------------------
out="$(run_hook "$FIX" "$(payload "git -C $CLEAN commit -m x" "$FIX")")"
check "clean repo allowed" ALLOW "$(verdict "$out")"

# --- 11. unstaged secret is not a commit hazard -----------------------------
# It scans --cached on purpose. Flagging working-tree files would fire on every
# commit in a repo that merely holds a gitignored .env.local — noise that trains
# the operator to ignore the channel.
echo "SECRET=1" > "$CLEAN/.env.local"
out="$(run_hook "$FIX" "$(payload "git -C $CLEAN commit -m x" "$FIX")")"
check "unstaged secret allowed (scans --cached)" ALLOW "$(verdict "$out")"
rm -f "$CLEAN/.env.local"

# --- 12-13. the other two forbidden patterns --------------------------------
for pat in id_rsa.key secrets.json; do
  P="$FIX/p_$pat"; mk_repo "$P"
  echo x > "$P/$pat"; git -C "$P" add -f "$pat" >/dev/null 2>&1
  out="$(run_hook "$FIX" "$(payload "git -C $P commit -m x" "$FIX")")"
  check "staged $pat -> deny" DENY "$(verdict "$out")"
done

# --- 14. non-git target: git itself would reject, nothing to scan -----------
out="$(run_hook "$FIX" "$(payload "git -C $NOGIT commit -m x" "$FIX")")"
check "non-git target allowed" ALLOW "$(verdict "$out")"

# 14V — is $NOGIT actually not a work tree? This is the assertion case 14 was
# always assumed to carry and never did. Under the old in-checkout fixture root
# the answer was `true`, so case 14 measured the ambient index instead of its
# stated subject and reported ALLOW for the wrong reason. Asserting the PREMISE
# separately is the only way an ALLOW here can mean what it says.
if git -C "$NOGIT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "  FAIL  14V \$NOGIT ($NOGIT) IS inside a work tree — case 14 above is"
  echo "        vacuous: the hook never took its non-repo branch, it scanned"
  echo "        whatever that repo has staged. Move the fixture root outside any"
  echo "        checkout."
  fail=$((fail+1))
else
  echo "  PASS  14V non-git target is genuinely outside any work tree (premise of 14)"
  pass=$((pass+1))
fi

# 14N — the paired positive control. Case 14 alone passes equally well against a
# hook that has stopped working, since ALLOW is also what a dead hook returns.
# Same directory shape, promoted to a real repo with a staged secret: it must now
# DENY. If 14 says ALLOW and 14N says DENY, the ALLOW came from the non-repo
# branch and not from the hook having quietly died.
NOGIT_R="$FIX/nogit_promoted"
mk_repo "$NOGIT_R"
echo "SECRET=1" > "$NOGIT_R/.env.local"
git -C "$NOGIT_R" add -f .env.local >/dev/null 2>&1
out="$(run_hook "$FIX" "$(payload "git -C $NOGIT_R commit -m x" "$FIX")")"
check "14N same shape, but a REAL repo with a staged secret -> deny (control for 14)" \
  DENY "$(verdict "$out")"

# 14S — structural pin. Without it, the next person to "simplify" the fixture
# root back under hooks/ silently restores the live leak, and case 14 goes back
# to reporting on the developer's index. A comment saying "keep this outside the
# repo" is a request; an assertion is enforcement.
scope="$(fixture_root_scope "$HOOK_DIR" "$FIX")"
check "14S fixture root sits outside the checkout under test" outside "$scope"

# --- 15-16. FAIL CLOSED when the toolchain cannot answer --------------------
# The original failure direction, inverted. These two are the reason the hook was
# rewritten: a degraded toolchain must BLOCK a commit-shaped command, not wave it
# through.
SHIM="$FIX/shim"; mkdir -p "$SHIM"

# Simulating "python absent" needs a PATH that still has a WORKING cat, because
# the hook reads its payload through `timeout 2 cat` before it ever looks for
# python. Copying cat into a bare shim dir does not survive: an MSYS binary
# cannot load msys-2.0.dll once PATH no longer reaches it, so cat dies, PAYLOAD
# is empty, the raw pre-filter sees no "commit", and the hook allows — a GREEN
# that proves nothing, because the hook never saw a commit-shaped command.
# /usr/bin has cat and timeout and, on the machines this was written against, no
# python — so it isolates the one variable. Verified rather than assumed, and
# skipped if that stops holding.
NOPY_PATH=""
if [ -x /usr/bin/cat ] && ! PATH=/usr/bin command -v python3 >/dev/null 2>&1 \
                       && ! PATH=/usr/bin command -v python  >/dev/null 2>&1; then
  NOPY_PATH=/usr/bin
fi
if [ -n "$NOPY_PATH" ]; then
  out="$(cd "$FIX" && printf '%s' "$(payload "git -C $DIRTY commit -m x" "$FIX")" \
         | PATH="$NOPY_PATH" bash "$HOOK" 2>&1)"
  check "python absent + commit-shaped -> deny (fail closed)" DENY "$(verdict "$out")"
else
  echo "  SKIP  python-absent case (no python-free PATH with a working cat here)"; skip=$((skip+1))
fi

# python present but crashing — the branch guarded by PYRC, distinct from absent.
cat > "$SHIM/python3" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$SHIM/python3"
out="$(cd "$FIX" && printf '%s' "$(payload "git -C $DIRTY commit -m x" "$FIX")" \
       | PATH="$SHIM:$PATH" bash "$HOOK" 2>&1)"
check "python crashes + commit-shaped -> deny (fail closed)" DENY "$(verdict "$out")"
rm -f "$SHIM/python3"

# A degraded toolchain must NOT block unrelated Bash. The raw pre-filter exists
# so a broken python never turns every command into a denial. Uses the same
# real-cat PATH as above — under the broken-cat shim this would pass vacuously.
if [ -n "$NOPY_PATH" ]; then
  out="$(cd "$FIX" && printf '%s' "$(payload 'ls -la' "$FIX")" | PATH="$NOPY_PATH" bash "$HOOK" 2>&1)"
  check "python absent + NON-commit -> still allowed" ALLOW "$(verdict "$out")"
else
  echo "  SKIP  python-absent non-commit case"; skip=$((skip+1))
fi

# --- 17. the deny must be valid JSON, from BOTH emitters --------------------
# emit_deny_plain builds JSON with printf rather than a serialiser, so a stray
# quote in the reason would emit a malformed object the harness silently ignores
# — a deny that does not deny.
PY="$(command -v python3 || command -v python || true)"
if [ -n "$PY" ]; then
  out="$(run_hook "$FIX" "$(payload "git -C $DIRTY commit -m x" "$FIX")")"
  if printf '%s' "$out" | "$PY" -X utf8 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d['hookSpecificOutput']['permissionDecision']=='deny' else 1)" 2>/dev/null; then
    echo "  PASS  deny payload is well-formed JSON"; pass=$((pass+1))
  else
    echo "  FAIL  deny payload is not parseable JSON:"; echo "$out" | sed 's/^/        /'; fail=$((fail+1))
  fi
else
  echo "  SKIP  JSON well-formedness (no python)"; skip=$((skip+1))
fi

echo "----------------------------------------"
echo "passed: $pass   failed: $fail   skipped: $skip"
[ "$fail" -eq 0 ] || exit 1
