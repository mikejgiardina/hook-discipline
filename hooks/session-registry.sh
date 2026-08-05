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
# atomic write leaves behind if a write is interrupted.
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
# Git-Bash. Writes are atomic (temp + os.replace), advisory last-writer-wins.
set -uo pipefail

MODE="${1:-register}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG="${HOOK_SESSION_REGISTRY:-$SCRIPT_DIR/.session-registry.json}"
STALE="${HOOK_SESSION_STALE_SECS:-1800}"

# Read stdin; `timeout` if present (Git-Bash/Linux), plain cat on macOS (no `timeout`).
if command -v timeout >/dev/null 2>&1; then
  RAW="$(timeout 2 cat 2>/dev/null || echo "")"
else
  RAW="$(cat 2>/dev/null || echo "")"
fi

# Advisory guard: no python -> no-op (never block a session on a degraded toolchain).
# Interpreter via lib/resolve-python.sh: `command -v` proves a name resolves, not
# that it RUNS (Windows ships a dead python3 alias stub).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/resolve-python.sh"
PY="$(resolve_python || true)"; [ -n "$PY" ] || exit 0

MODE="$MODE" REG="$REG" STALE="$STALE" REG_RAW="$RAW" "$PY" -X utf8 - <<'PY'
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

def load():
    try:
        with open(reg, "r", encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}

def save(d):
    tmp = "%s.tmp.%d" % (reg, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f)
        os.replace(tmp, reg)  # atomic on POSIX and Windows (same filesystem)
    except Exception:
        try:
            os.remove(tmp)
        except Exception:
            pass

d = load()
# Prune anything we can no longer trust as live BEFORE any decision uses it.
d = {k: v for k, v in d.items()
     if isinstance(v, dict) and (now - int(v.get("heartbeat", 0) or 0)) <= stale}

if mode == "deregister":
    d.pop(sid, None)
    save(d)
    sys.exit(0)

# Upsert self for register / heartbeat.
me = d.get(sid, {})
if not isinstance(me, dict):
    me = {}
me.setdefault("started", now)
me.setdefault("repos", {})           # {repo_toplevel: last_active_ts} — filled by worktree-guard.sh
me["cwd"] = cwd
me["heartbeat"] = now
d[sid] = me
save(d)

if mode != "register":
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
