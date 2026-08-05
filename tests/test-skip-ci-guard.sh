#!/bin/bash
# Behavioral tests for hooks/skip-ci-guard.sh — keeps the CI-skip marker off
# feature-branch commits.
#
# === What this guards ===
# The convention says "put the skip marker on the commit subject". Applied while
# committing on a FEATURE BRANCH it suppresses the pull_request trigger, and
# because merges to the default branch also carry the marker, such a PR gets no
# CI anywhere. A retrospective check found most branches in a sample had no CI
# runs at all; one change reached the default branch completely untested.
#
# The cases that carry the weight:
#   * marker on a feature-branch commit is DENIED
#   * marker on a default-branch commit is ALLOWED (the churn case the
#     convention exists for — denying it would just move the damage)
#   * a commit that merely QUOTES the marker is denied too, because GitHub
#     matches tokens anywhere in the message and such a commit really does skip
#     itself. That is the property that made the original incident hard to see.
#
# Run: bash tests/test-skip-ci-guard.sh
# Exits non-zero on any failure.

set -u
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)"
HOOK="$HOOK_DIR/skip-ci-guard.sh"
[ -f "$HOOK" ] || { echo "FATAL: $HOOK not found"; exit 1; }

PY="$(command -v python3 || command -v python || echo python)"
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


# Real throwaway git repos — the hook resolves the branch with `git -C <cwd>`,
# so a fake cwd would make every case take the fail-open path and pass
# vacuously. That is the standing mistake this repo keeps making: a suite that
# is green because the branch under test never executed.
#
# The shared helper rather than a bare `mktemp -d`, because the fixture root has
# to be consumable by BOTH bash and a native Windows python — the hook hands the
# payload cwd to python, which shells back out to git. `mktemp -d` alone returns
# a mount-point path that the native side cannot resolve, so every case would
# silently take the fail-open branch. See tests/lib/fixture-root.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)/fixture-root.sh"
fixture_root_init skipci

mkrepo() {   # $1=name $2=branch
  local d="$FIX/$1"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email t@t.io; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m "root" 2>/dev/null
  git -C "$d" checkout -q -B "$2" 2>/dev/null
  printf '%s' "$d"
}
FEATURE="$(mkrepo feat  fix/123-thing)"
MAIN="$(mkrepo   mainr  main)"
MASTER="$(mkrepo mastr  master)"

payload() {  # $1=command $2=cwd
  printf '{"tool_name":"Bash","tool_input":{"command":%s},"cwd":%s}' \
    "$("$PY" -X utf8 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$1")" \
    "$("$PY" -X utf8 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$2")"
}

check() {    # $1=label $2=cmd $3=cwd $4=DENY|ALLOW
  local label="$1" cmd="$2" cwd="$3" want="$4" out got
  out="$(payload "$cmd" "$cwd" | bash "$HOOK" 2>/dev/null)"
  if printf '%s' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then got=DENY; else got=ALLOW; fi
  if [ "$got" = "$want" ]; then echo "  PASS  $label"; pass=$((pass+1))
  else echo "  FAIL  $label — wanted $want, got $got"; fail=$((fail+1)); fi
}

# The literal tokens are assembled at runtime. Written inline, this test file
# would be fine (files are not commit messages) but the COMMIT that adds it
# would carry them and skip its own CI — the very trap under test.
B="["; E="]"
SKIP="${B}skip ci${E}"; CISKIP="${B}ci skip${E}"; NOCI="${B}no ci${E}"
SKIPACT="${B}skip actions${E}"; DASH="${B}skip-ci${E}"

echo "skip-ci-guard.sh"

echo
echo "the case the guard exists for"
check "marker on a FEATURE-branch commit is denied" \
  "git commit -m \"fix(x): thing $SKIP\"" "$FEATURE" DENY
# Positive control: identical command, identical repo shape, marker removed. If
# this ever reports DENY the case above proves nothing — it would mean the hook
# denies every commit rather than marker-bearing ones.
check "  control: same commit WITHOUT the marker allowed" \
  'git commit -m "fix(x): thing"' "$FEATURE" ALLOW

echo
echo "default-branch commits keep the marker — the churn case the convention exists for"
check "marker on main is allowed"                   "git commit -m \"chore: restamp $SKIP\"" "$MAIN"   ALLOW
check "marker on master is allowed"                 "git commit -m \"chore: restamp $SKIP\"" "$MASTER" ALLOW

echo
echo "every GitHub skip token, not just the common one"
check "ci skip"                                     "git commit -m \"x $CISKIP\""  "$FEATURE" DENY
check "no ci"                                       "git commit -m \"x $NOCI\""    "$FEATURE" DENY
check "skip actions"                                "git commit -m \"x $SKIPACT\"" "$FEATURE" DENY
check "hyphenated skip-ci"                          "git commit -m \"x $DASH\""    "$FEATURE" DENY
check "case-insensitive"                            "git commit -m \"x ${B}Skip CI${E}\"" "$FEATURE" DENY

echo
echo "the body case — GitHub matches anywhere, so a commit that QUOTES the marker skips itself"
# The original incident's first two pushes produced no run: clean subject, marker
# quoted twice in the body while explaining the problem. Removing the literal
# token made CI fire on the same diff.
check "marker in the BODY of a -F heredoc is denied" \
  "git commit -F - <<'EOF'
fix(ci): explain the convention

The marker is $SKIP and it is applied at merge time.
EOF" "$FEATURE" DENY
check "marker in a second -m body paragraph"        "git commit -m \"subject\" -m \"body mentions $SKIP\"" "$FEATURE" DENY

echo
echo "escape hatch"
check "HOOK_ALLOW_SKIP_CI=1 permits it"             "HOOK_ALLOW_SKIP_CI=1 git commit -m \"x $SKIP\"" "$FEATURE" ALLOW

echo
echo "no false positives"
check "commit with no marker"                       'git commit -m "fix(x): ordinary work"' "$FEATURE" ALLOW
check "marker in prose, NOT a git commit"           "echo \"the marker is $SKIP\"" "$FEATURE" ALLOW
# The command below is never executed — the hook is PreToolUse and only inspects
# the string. Merge is the RIGHT place for the marker, so this must not deny.
check "a merge command carrying the marker is allowed" \
  "gh pr merge 5 --squash --subject \"t $SKIP (#5)\"" "$FEATURE" ALLOW
check "unrelated git command"                       'git status' "$FEATURE" ALLOW
check "commit-ish word in prose"                    "echo 'commit the marker $SKIP later'" "$FEATURE" ALLOW

echo
echo "degenerate input must never crash or block"
for body in '' '{"tool_input":' '{"tool_input":{}}'; do
  printf '%s' "$body" | bash "$HOOK" >/dev/null 2>&1
  rc=$?
  [ $rc -eq 0 ] && { echo "  PASS  degenerate payload -> exit 0"; pass=$((pass+1)); } \
                || { echo "  FAIL  degenerate payload -> exit $rc"; fail=$((fail+1)); }
done
# Unresolvable cwd must fail OPEN — a degraded toolchain cannot stop committing.
check "unresolvable repo fails open"                "git commit -m \"x $SKIP\"" "$FIX/not-a-repo" ALLOW

echo
echo "the missing-dependency branch must be LOUD"
# This hook imports CMD_START and to_native_path from lib/cmdparse.py. If that
# import fails it allows — correct, it is fail-open — but it must SAY so.
# Otherwise the marker check is silently off and every commit sails through
# looking checked.
#
# The sibling guard got this block when its import branch was written; this one
# did not, and the asymmetry survived a review pass. Worth stating plainly: the
# newest code in a repository whose entire thesis is "an untested check is the
# failure mode" had exactly that gap, in one of the two places the branch was
# introduced. That is how ordinary it is.
#
# D0 and D3 are what stop D1 being vacuous — D0 proves the stripped mirror really
# lacks the module, D3 proves the equipped one does not warn unconditionally.
BARE="$FIX/bare"
mkdir -p "$BARE/hooks" "$BARE/lib"
cp "$HOOK" "$BARE/hooks/skip-ci-guard.sh"
cp "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/resolve-python.sh" "$BARE/lib/"
# cmdparse.py deliberately NOT copied.

if [ ! -f "$BARE/lib/cmdparse.py" ]; then
  echo "  PASS  D0 the stripped mirror genuinely lacks cmdparse (premise of D1)"; pass=$((pass+1))
else
  echo "  FAIL  D0 stripped mirror still has cmdparse — D1 would be vacuous"; fail=$((fail+1))
fi

D_ERR="$(payload "git commit -m \"x $SKIP\"" "$FEATURE" \
         | bash "$BARE/hooks/skip-ci-guard.sh" 2>&1 >/dev/null)"
D_RC=$?
if printf '%s' "$D_ERR" | grep -q 'cmdparse'; then
  echo "  PASS  D1 a missing dependency is announced on stderr, not swallowed"; pass=$((pass+1))
else
  echo "  FAIL  D1 missing cmdparse degraded SILENTLY — the marker check is off"; fail=$((fail+1))
  echo "        and every commit looks checked. stderr was: '$D_ERR'"
fi

if [ "$D_RC" -eq 0 ]; then
  echo "  PASS  D2 ...and still exits 0 (loud, not fatal — committing must not break)"; pass=$((pass+1))
else
  echo "  FAIL  D2 degraded path exited $D_RC — a fail-open guard must not block"; fail=$((fail+1))
fi

E_ERR="$(payload "git commit -m \"x $SKIP\"" "$FEATURE" | bash "$HOOK" 2>&1 >/dev/null)"
if printf '%s' "$E_ERR" | grep -q 'cmdparse'; then
  echo "  FAIL  D3 the EQUIPPED hook also warns — D1 proves nothing"; fail=$((fail+1))
else
  echo "  PASS  D3 the equipped hook stays quiet (control for D1)"; pass=$((pass+1))
fi

echo
echo "----------------------------------------"
echo "passed: $pass   failed: $fail   skipped: $skip"
[ "$fail" -eq 0 ] || exit 1
