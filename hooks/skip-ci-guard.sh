#!/usr/bin/env bash
# skip-ci-guard.sh — PreToolUse(Bash) hook. Keeps the CI-skip marker off FEATURE
# BRANCH commits, where it suppresses the `pull_request` run; merges to the
# default branch also carry the marker, so such a PR gets no CI anywhere.
#
#   feature branch commit  -> marker FORBIDDEN (this hook denies it)
#   default branch commit  -> marker fine; mechanical churn should not run CI
#   merge commit           -> marker wanted; add it to the merge subject
#
# The whole command is scanned and heredocs are NOT stripped: the message can
# arrive as -m, repeated -m, --message=, or a heredoc body via `-F -`.
# A commit that merely WRITES ABOUT the marker is denied on purpose: GitHub
# matches the token anywhere in the message, so it does skip itself.
#
# Fail-open, but LOUD: if the branch cannot be determined it says so on stderr
# and allows. Blocking goes through stdout JSON permissionDecision:deny at exit 0,
# because the settings wiring's `|| true` swallows exit codes.
#
# Escape hatch:
#   HOOK_ALLOW_SKIP_CI=1   prefix the command; use when you genuinely intend a
#                          branch commit to skip CI and accept it is untested.
set -uo pipefail

if command -v timeout >/dev/null 2>&1; then
  # A timeout exiting neither 0 nor 124 is not GNU coreutils and never read stdin
  # (Windows' System32 timeout.exe exits 1): read stdin directly instead of
  # continuing with an empty payload, which every guard would read as "allow".
  PAYLOAD=$(timeout 2 cat 2>/dev/null) || { _trc=$?; [ "$_trc" -eq 124 ] || PAYLOAD=$(cat 2>/dev/null || echo ""); }
else
  PAYLOAD=$(cat 2>/dev/null || echo "")
fi

# Cheap raw pre-filter — anything that cannot be a marker-bearing commit exits
# untouched. Deliberately over-matches; the python side re-checks properly.
case "$PAYLOAD" in
  *commit*) ;;
  *) exit 0 ;;
esac

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
. "$LIB_DIR/resolve-python.sh"
PY="$(resolve_python || true)"
if [ -z "$PY" ]; then
  printf 'skip-ci-guard: python not found — CI-marker checking is NOT active for this call.\n' >&2
  exit 0
fi

SG_PAYLOAD="$PAYLOAD" SCG_LIB="$LIB_DIR" "$PY" -X utf8 - <<'PY'
import os, re, sys, json, subprocess

raw = os.environ.get("SG_PAYLOAD", "")

def deny(reason):
    reason = reason.replace('"', "'").replace("\\", "/").replace("\n", " ")
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)

try:
    payload = json.loads(raw) if raw.strip() else {}
except Exception:
    sys.stderr.write("skip-ci-guard: unparseable payload — CI-marker checking NOT active for this call.\n")
    sys.exit(0)

ti  = payload.get("tool_input") or {}
cmd = ti.get("command", "") if isinstance(ti, dict) else ""
if not cmd:
    sys.exit(0)

# --- shared command/path parsing ---------------------------------------------
# The command and path parsing comes from lib/cmdparse.py rather than being
# copied in here. That module exists precisely because two sibling guards once
# carried hand-copies of this logic, one got hardened and the other did not, and
# the drifted one then fired on prose. Re-inlining it here to make this file
# self-contained would rebuild the same trap.
#
# search_cmd anchors a verb to a position where a command can actually start
# (CMD_START), looking for that position outside quoted strings. Backtick is
# deliberately excluded as an anchor: a verb after a backtick is overwhelmingly
# a markdown code span, and matching it turns "writing about a command" into
# "running one" — a guard whose false positives scale with how often you
# document the thing it guards.
#
# git_invocation and git_global_args handle git's own options that come before
# the subcommand, and which of them select a different repository.
#
# to_native_path handles the MSYS boundary. A path passed as a STANDALONE env var
# is auto-converted by MSYS on the way to a native binary; a path EMBEDDED IN A
# STRING is not, and the hook payload is JSON. Hence SCG_LIB below arrives native
# while the payload's own cwd does not. git_global_args applies it to paths it
# reads from the command for the same reason.
#
# The import failure is LOUD, not silent. Degrading to a no-op would leave the
# guard running, returning verdicts, and quietly blind to a whole class of
# commands — fail-silent rather than fail-open. This hook is already fail-open by
# design; that is a decision about what to do without a verdict, not permission to
# conceal that there wasn't one.
sys.path.insert(0, os.environ.get("SCG_LIB", ""))
try:
    from cmdparse import git_global_args, git_invocation, search_cmd, to_native_path
except Exception as e:
    sys.stderr.write(
        "skip-ci-guard: cannot import cmdparse (%s) — CI-marker checking is NOT "
        "active for this call.\n" % e
    )
    sys.exit(0)

# Explicit, recorded opt-out. Checked before anything else so it works even when
# the branch cannot be resolved.
if re.search(r"\bHOOK_ALLOW_SKIP_CI=1\b", cmd):
    sys.exit(0)

# `git commit` in COMMAND position — not `echo "git commit …"`, not a --message
# that happens to quote one. Heredocs are deliberately left intact: for
# `git commit -F -` the heredoc body IS the message being checked.
#
# Two things the anchor has to get right:
#   * Global options before the subcommand. Some take a separate argument
#     (`git -C <dir> commit`, `git -c <k=v> commit`, `git --git-dir <dir>
#     commit`). Skipping only tokens that start with `-` stopped at that
#     argument, and such a commit was never checked. git_invocation knows which
#     options take one.
#   * Quoted data. search_cmd looks for the command-position anchor with quoted
#     contents masked, so `printf '%s' 'cd x && git commit …'` is not read as a
#     commit. The masking applies only to finding the anchor: the skip-token
#     search below still reads the whole command, because a quoted -m argument
#     or a heredoc body is exactly where the message lives.
inv = search_cmd(git_invocation("commit"), cmd)
if not inv:
    sys.exit(0)

# GitHub's documented skip tokens, matched anywhere in the message exactly as
# GitHub matches them — subject or body, case-insensitive.
TOKENS = r"\[(?:skip[ -]ci|ci[ -]skip|no[ -]ci|skip[ -]actions|actions[ -]skip)\]"
m = re.search(TOKENS, cmd, re.I)
if not m:
    sys.exit(0)
token = m.group(0)

cwd = to_native_path(payload.get("cwd") or "") or None

# Read the branch of the repository the commit acts on. That is the payload cwd
# adjusted by any -C, --git-dir and --work-tree given to this git invocation.
# Those options are handed back to git in their original order, so git applies
# its own rules: each -C relative to the one before, an absolute -C replacing
# what came before, --git-dir and --work-tree relative to the result.
#
# If one of them depends on shell expansion (`-C "$DIR"`), the target cannot be
# known from the text. The session cwd is checked instead, which is what this
# hook did before it read -C at all; it says so on stderr.
target = git_global_args(inv.group(1))
if target is None:
    sys.stderr.write(
        "skip-ci-guard: the commit's target repository depends on shell expansion — "
        "checking the session directory's branch instead.\n")
    target = []

def git(*args):
    try:
        r = subprocess.run(["git"] + (["-C", cwd] if cwd else []) + target + list(args),
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None

branch = git("rev-parse", "--abbrev-ref", "HEAD")
if not branch:
    # Fail open, loudly. A repo we cannot resolve must not block committing.
    sys.stderr.write(
        "skip-ci-guard: could not resolve the current branch — NOT checking the CI marker "
        "for this call. If this is a feature branch, the marker will disable its PR run.\n")
    sys.exit(0)

# Default-branch commits legitimately carry the marker: that is the mechanical
# churn case the convention was written for. Both names are accepted because
# repositories differ on which one they use, and a hook that only knew one would
# silently deny legitimate commits in half of them.
if branch in ("main", "master", "HEAD"):
    sys.exit(0)

deny(
    "skip-ci-guard: '%s' in a commit on branch '%s' would disable this PR's ONLY CI run. "
    "GitHub matches skip tokens anywhere in the message, subject OR body, so a commit that merely "
    "quotes the marker also skips itself — that is not hypothetical, it is how this hook was found. "
    "Because merges to the default branch also carry the marker, a PR authored this way gets NO CI "
    "at all: not on the branch, not post-merge. FIX: drop the marker from this commit. The merge "
    "still skips CI — put the marker on the MERGE subject when you land the PR instead, so branch "
    "commits stay clean and the PR run actually happens. Writing ABOUT the marker? Don't put the "
    "literal token in a commit message; name it in prose, or use a git trailer. Genuinely intend to "
    "skip? Prefix the command with HOOK_ALLOW_SKIP_CI=1."
    % (token, branch))
PY
