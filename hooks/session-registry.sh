#!/usr/bin/env bash
# session-registry.sh — machine-local live-session registry, the warn-half of
# parallel-session worktree isolation. Pairs with worktree-guard.sh.
#
# === What this solves ===
# Branch-per-thread isolates *branches* but not the *working tree*. When more than
# one agent session runs against the same workspace, they share the checkouts under
# it — and `git checkout` plus uncommitted changes are global to a tree. In
# practice this produced commits landing on another session's branch and threads
# split mid-commit. The fix is per-session worktrees; this registry is the
# *warn-the-agent* half that makes the agent actually reach for one.
#
# === State file ===
# Shares one registry with worktree-guard.sh:  hooks/.session-registry.json
# (override with HOOK_SESSION_REGISTRY). It is machine-local runtime state, not
# source — GITIGNORE IT, along with the `.session-registry.json.tmp.*` files the
# atomic write leaves behind if a write is interrupted, the
# `.session-registry.json.lock` file that serialises writers, and any
# `.session-registry.json.corrupt.<epoch>` file a damaged registry is moved to.
#
# === Concurrency (lib/jsonstate.py) ===
# Every session runs this hook on every turn, and worktree-guard.sh writes the
# same file on every git command, so writers overlap routinely. Each
# read-modify-write runs under one O_EXCL lockfile. Without it, two writers that
# loaded the same version each wrote back only their own change, and the second
# erased the first.
#
# A registry that exists but cannot be parsed is NOT read as empty. Reading it as
# empty is how the next save used to erase every peer without a word. It is moved
# aside to `<registry>.corrupt.<epoch>`, kept as evidence, and the registry starts
# fresh, with a notice; peers reappear at their next heartbeat. Starting fresh
# rather than refusing to write keeps one damaged file from disabling the
# registry for every later session.
#
# === Modes (argv[1]) ===
#   register    SessionStart  — prune stale entries, upsert self, and if ANOTHER
#                               live session shares this workspace, print an
#                               agent-actionable warning to stdout. SessionStart
#                               stdout is added to the model's context, so the
#                               agent sees it and can worktree before working.
#   heartbeat   Stop          — silently bump this session's liveness timestamp
#                               (one tick per assistant turn = the liveness signal).
#   deregister  SessionEnd    — silently drop this session. The staleness prune
#                               (HOOK_SESSION_STALE_SECS, default 30 min) is the
#                               backstop if SessionEnd never fires (crash/kill).
#
# === Design posture ===
# ADVISORY, fail-open: this is a safety convenience, not a security gate (opposite
# of secrets-scan.sh). If python is missing, the payload is unparseable, or cwd is
# outside any git repo, it no-ops silently — it must never block a session start.
# jq-free (python for JSON) so the same file works on a Windows box with only
# Git-Bash. Writes are atomic (temp + os.replace) and serialised by a lockfile;
# a write that cannot get the lock within a few seconds is skipped, not forced.
set -uo pipefail

MODE="${1:-register}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
REG="${HOOK_SESSION_REGISTRY:-$SCRIPT_DIR/.session-registry.json}"
STALE="${HOOK_SESSION_STALE_SECS:-1800}"

# Read stdin; `timeout` if present (Git-Bash/Linux), plain cat on macOS (no `timeout`).
if command -v timeout >/dev/null 2>&1; then
  # A timeout exiting neither 0 nor 124 is not GNU coreutils and never read stdin
  # (Windows' System32 timeout.exe exits 1): read stdin directly instead of
  # continuing with an empty payload, which every guard would read as "allow".
  RAW="$(timeout 2 cat 2>/dev/null)" || { _trc=$?; [ "$_trc" -eq 124 ] || RAW="$(cat 2>/dev/null || echo "")"; }
else
  RAW="$(cat 2>/dev/null || echo "")"
fi

# Advisory guard: no python -> no-op (never block a session on a degraded toolchain).
# Interpreter via lib/resolve-python.sh: `command -v` proves a name resolves, not
# that it RUNS (Windows ships a dead python3 alias stub).
. "$LIB_DIR/resolve-python.sh"
PY="$(resolve_python || true)"; [ -n "$PY" ] || exit 0

# REG_LIB travels as a standalone env var so Git Bash hands a Windows python the
# native form of the path (see the same note in worktree-guard.sh).
MODE="$MODE" REG="$REG" STALE="$STALE" REG_RAW="$RAW" REG_LIB="$LIB_DIR" "$PY" -X utf8 - <<'PY'
import os, sys, json, time

mode  = os.environ.get("MODE", "register")
reg   = os.environ.get("REG")
try:
    stale = int(os.environ.get("STALE", "1800") or "1800")
except Exception:
    stale = 1800
raw   = os.environ.get("REG_RAW", "")

try:
    payload = json.loads(raw) if raw.strip() else {}
except Exception:
    payload = {}

# Env fallback for when the payload carries no session_id. CLAUDE_CODE_SESSION_ID
# is the name current builds actually set; CLAUDE_SESSION_ID is kept for other or
# older builds but was found UNSET. Before that was checked, the fallback was
# CLAUDE_SESSION_ID alone and had therefore never once fired: any payload missing
# session_id fell straight to the exit below and the session went UNREGISTERED,
# silently. That degrades every consumer -- worktree-guard stops warning about the
# session, and anything using registry liveness (a lock-ownership check, say)
# reports a live owner as dead. Worth checking rather than assuming which env var
# a runtime sets: a fallback that never fires looks identical to one that is never
# needed.
sid = (payload.get("session_id")
       or os.environ.get("CLAUDE_CODE_SESSION_ID")
       or os.environ.get("CLAUDE_SESSION_ID")
       or "").strip()
cwd = (payload.get("cwd") or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd() or "").strip()
if not sid:
    sys.exit(0)  # cannot track an anonymous session; fail open

now = int(time.time())

sys.path.insert(0, os.environ.get("REG_LIB", ""))
try:
    import jsonstate as js
except Exception as e:
    sys.stderr.write("session-registry: cannot import lib/jsonstate.py (%s) -- "
                     "registry NOT updated.\n" % e)
    sys.exit(0)

def update():
    """One read-modify-write. Call only while holding the registry lock.
    Returns the registry as written, or None when the write was skipped."""
    try:
        d = js.load(reg)
    except js.Corrupt as e:
        # Writers serialise on the lock and replace atomically, so a damaged file
        # came from outside that protocol. Move it aside rather than overwrite it
        # (the evidence is kept and nothing is erased unannounced), then start
        # fresh so one bad file cannot disable the registry for good.
        q = "%s.corrupt.%d" % (reg, now)
        try:
            os.replace(reg, q)
        except Exception:
            sys.stderr.write("session-registry: %s is unreadable (%s) and could not be "
                             "moved aside -- registry NOT updated.\n" % (reg, e))
            return None
        msg = ("session-registry: %s was unreadable (%s); moved it aside to %s and "
               "started fresh -- peer sessions reappear at their next heartbeat."
               % (reg, e, q))
        sys.stderr.write(msg + "\n")
        if mode == "register":
            print(msg)  # SessionStart stdout reaches the session; stderr may not
        d = {}

    # Prune anything we can no longer trust as live BEFORE any decision uses it.
    d = {k: v for k, v in d.items()
         if isinstance(v, dict) and (now - int(v.get("heartbeat", 0) or 0)) <= stale}

    if mode == "deregister":
        d.pop(sid, None)
        js.save(reg, d)
        return d

    # Upsert self for register / heartbeat.
    me = d.get(sid, {})
    if not isinstance(me, dict):
        me = {}
    me.setdefault("started", now)
    me.setdefault("repos", {})       # {repo_toplevel: last_active_ts} — filled by worktree-guard.sh
    me["cwd"] = cwd
    me["heartbeat"] = now
    d[sid] = me
    js.save(reg, d)
    return d

try:
    with js.locked(reg, timeout=5, stale=30):
        d = update()
except js.LockTimeout:
    sys.stderr.write("session-registry: registry lock is busy -- this update was "
                     "skipped; the next heartbeat retries.\n")
    sys.exit(0)

if d is None or mode != "register":
    sys.exit(0)

# --- register: warn if another live session shares this workspace -------------
others = {k: v for k, v in d.items() if k != sid}
if not others:
    sys.exit(0)

lines = []
for k, v in others.items():
    repos = v.get("repos") or {}
    active = sorted(os.path.basename(r) for r, ts in repos.items()
                    if (now - int(ts or 0)) <= stale)
    ago = max(0, (now - int(v.get("heartbeat", now) or now)) // 60)
    where = (", active in: " + ", ".join(active)) if active else ""
    lines.append("  - session %s... (last seen %dm ago%s)" % (k[:8], ago, where))

print(
    "[WORKTREE GUARD] %d other live agent session(s) share this workspace:\n%s\n"
    "The working tree -- not just the branch -- is the contended resource. Two sessions editing the\n"
    "SAME checkout commit onto each other's branches and split threads mid-commit. Before you edit\n"
    "or commit in a repo another session is in:\n"
    "  give THIS session its own worktree --  git -C <repo> worktree add ../<repo>-<thread> -b feature/<thread>\n"
    "  (then point your work there),  OR confirm with the user the other session is idle / won't touch\n"
    "the same repo. Assess overlap and resolve it BEFORE touching files -- don't treat this as a passive\n"
    "notice."
    % (len(others), "\n".join(lines))
)
PY
