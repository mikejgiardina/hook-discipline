#!/usr/bin/env bash
# payload.sh — shared payload reader for Write/Edit-bound hooks. SOURCE it, don't run it.
#
# === Why this exists ===
# A whole family of PostToolUse(Write|Edit) hooks read the edited file's path
# from an environment variable named $CLAUDE_TOOL_INPUT.
#
# That variable has never been part of the Claude Code hook contract. Command
# hooks receive their input ONLY as JSON on stdin. The documented environment
# variables are CLAUDE_PROJECT_DIR, CLAUDE_PLUGIN_ROOT, CLAUDE_PLUGIN_DATA,
# CLAUDE_EFFORT, CLAUDE_CODE_REMOTE and CLAUDE_CODE_BRIDGE_SESSION_ID. There is
# no CLAUDE_TOOL_INPUT among them.
#
# So the variable expanded to the empty string, the path variable was empty, and
# every one of those hooks exited at its second line. Forever. Silently, because
# the wiring ran them under `2>/dev/null || true`. Among them was the hook whose
# job was scanning outward-facing files before publication — a check that had
# never once looked at a file, reporting success every time.
#
# The part worth dwelling on is how the belief spread. Read the header comments
# those hooks carried and they cite EACH OTHER as "the working hook convention".
# They vouched for a convention none of them had ever tested end to end. One went
# further and asserted in prose that the variable "is set for PostToolUse" — in a
# hook that reads stdin, and was therefore never in a position to find out.
#
# That is why this is one shared reader rather than another hand-copied block.
# The duplication was not just repetition; it was what made the wrong belief look
# corroborated.
#
# === Contract ===
#   hook_payload            -> echoes the raw stdin JSON (empty string if none)
#   hook_file_path <json>   -> echoes .tool_input.file_path, unescaped, or ""
#
# jq-free (grep/sed only) on purpose. jq is not present everywhere these hooks
# run, and a hook that silently degrades when a dependency is missing is the
# failure mode this whole layer is written against.

# Read stdin. Use `timeout` where it exists (Git Bash, Linux); fall back to plain
# `cat` on stock macOS, which does not ship a `timeout` binary.
#
# The $CLAUDE_TOOL_INPUT fallback below is deliberate but demoted: it costs
# nothing and means nothing regresses if some future build ever does set it.
# stdin is the contract; the env var is a courtesy.
hook_payload() {
  local p=""
  if command -v timeout >/dev/null 2>&1; then
    # A timeout exiting neither 0 nor 124 is not GNU coreutils and never read stdin
    # (Windows' System32 timeout.exe exits 1): read stdin directly instead of
    # continuing with an empty payload, which every guard would read as "allow".
    p="$(timeout 2 cat 2>/dev/null)" || { _trc=$?; [ "$_trc" -eq 124 ] || p="$(cat 2>/dev/null || echo "")"; }
  else
    p="$(cat 2>/dev/null || echo "")"
  fi
  [ -n "$p" ] || p="${CLAUDE_TOOL_INPUT:-}"
  printf '%s' "$p"
}

# Extract the edited path. Matches "file_path" wherever it appears, so this works
# for the real nested payload ({"tool_input":{"file_path":...}}) and for a flat
# {"file_path":...} object alike.
#
# A Windows payload carries "C:\\project\\src\\x.py" with DOUBLED backslashes, so
# \\ -> \ , \/ -> / and \" -> " are unescaped before returning. Measured: the
# doubled form happens to survive both `[ -f ]` and the usual `tr '\\' '/'` glob
# normalization, so this is normalization for sanity and NOT a load-bearing fix.
# Don't cite it as one.
#
# The `([^"\\]|\\.)*` capture IS load-bearing: it stops the match from truncating
# at an escaped quote inside the value.
#
# This is not a general JSON unescaper — \uXXXX, \t, and a literal \\ immediately
# before an escaped quote are not handled. Filenames needing those are
# pathological, and Windows forbids `"` in a path outright.
hook_file_path() {
  printf '%s' "${1:-}" \
    | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' \
    | head -1 \
    | sed -E 's/^"file_path"[[:space:]]*:[[:space:]]*"(.*)"$/\1/' \
    | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g' -e 's/\\\//\//g' || true
}
# The trailing `|| true` is not cosmetic, and it is the single most reusable line
# in this file.
#
# Callers that run under `set -euo pipefail` hit this chain: a no-match `grep`
# returns 1, `pipefail` promotes that to the whole pipeline's status, and
# `errexit` then kills the script ON THE ASSIGNMENT LINE. Not at the point of
# use — at the assignment. The hook dies before it has done anything, exits
# non-zero into a wrapper that discards exit codes, and goes quiet.
#
# That is a real hook that spent a month dead in exactly this way. A payload with
# no file_path is NORMAL, not an error, so it must return empty and exit 0.
