#!/usr/bin/env bash
# resolve-python.sh — shared interpreter resolver. SOURCE it, don't run it.
#
# === Why this exists ===
# Every python-using hook in this layer once carried the same line:
#
#   PY="$(command -v python3 || command -v python || true)"
#
# The stated intent, per the comment each copy carried, was "python3-first so
# this resolves on macOS, which has no bare `python`". That reasoning is sound
# and is preserved below. The unstated assumption is not: the expression treats
# `command -v python3` SUCCEEDING as proof that python3 RUNS.
#
# On Windows 11 that assumption is false. The OS ships an App-Execution-Alias
# stub at %LOCALAPPDATA%\Microsoft\WindowsApps\python3.exe which prints a
# Microsoft Store advertisement and exits 49. Real Python ships python.exe and
# no python3.exe. So on a machine with a perfectly good Python installed:
#
#   command -v python3     -> SUCCEEDS  (it resolves the stub)
#   `|| command -v python` -> never fires, because the left side succeeded
#   [ -z "$PY" ]           -> false, because PY is non-empty
#
# PY ends up non-empty and non-functional, and every downstream guard that tests
# for emptiness waves it through. The hook that found this fails CLOSED by
# design, so the observed symptom was every commit on the machine being blocked
# — by an error message naming the secrets scanner rather than the toolchain.
#
# The blast radius was wider than the one hook, and the reason is worth keeping
# in mind when you write a pre-filter: that scanner pre-filters on the substring
# `commit`, so any shell command merely CONTAINING that word was routed into the
# broken path and denied too. That included the commands someone would naturally
# reach for to diagnose it.
#
# === The rule this encodes ===
# `command -v` proves a NAME RESOLVES. It does not prove the thing RUNS. On
# Windows the two come apart routinely, and not only for python — the same shape
# turned up three times on one box:
#
#   python3  -> WindowsApps alias stub                -> exits 49 with a Store ad
#   bash     -> WindowsApps WSL alias, no distro      -> execvpe failure
#   bash     -> C:\WINDOWS\system32\bash.exe (WSL2)   -> installed silently by
#               Docker Desktop; system32 is on the MACHINE PATH, so it outranks
#               Git\bin no matter where you put Git\bin in the USER PATH
#
# So: probe every candidate before accepting it. Ordering stays python3-first,
# which is what keeps stock macOS (no bare `python`) working.
#
# Anything a script resolves via `command -v` and then EXECUTES wants the same
# treatment. The probe is the cheap half; remembering to doubt the resolver is
# the expensive half.
#
# === Contract ===
#   resolve_python   -> echoes an interpreter that answered `--version` with
#                       "Python 3", and returns 0.
#                       Echoes NOTHING and returns 1 when none does.
#
# Callers keep their existing posture by wrapping the call, so converting a call
# site is a one-expression diff and the fail-open/fail-closed choice each hook
# already made is preserved verbatim:
#
#   PY="$(resolve_python || echo python)"   # last-resort literal (advisory hooks)
#   PY="$(resolve_python || true)"          # then test [ -z "$PY" ] and decide
#
# === Escape hatch ===
# HOOK_PYTHON=/path/to/python pins an interpreter and skips discovery. It is
# still probed — a pin that does not run is a configuration error worth failing
# on, not a way to smuggle a dead interpreter past the check.
#
# === Cost ===
# One `--version` spawn per candidate, and only on the path that actually needs
# python. That is affordable because a well-written PreToolUse hook pre-filters
# and exits BEFORE its PY line on the overwhelming majority of calls. Check that
# yours does; resolving an interpreter above the scope filter means paying for it
# on every single tool call, which is how a ~470ms cost per write gets introduced
# by a line that is not even referenced further down.
#
# Do not "optimize" this by caching the answer to a file. A cache that can go
# stale reintroduces exactly the class of bug this file exists to close, and buys
# nothing on the hot path.

# Probe one candidate. Kept as a separate function so a test suite can exercise
# the accept/reject decision directly rather than only through PATH ordering.
_probe_python() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  # 2>&1 because the WindowsApps stub writes its Store nag to stdout on some
  # builds and stderr on others; either way it does not say "Python 3".
  case "$("$p" --version 2>&1)" in
    "Python 3"*) return 0 ;;
  esac
  return 1
}

resolve_python() {
  local c p
  if [ -n "${HOOK_PYTHON:-}" ]; then
    if _probe_python "$HOOK_PYTHON"; then
      printf '%s' "$HOOK_PYTHON"
      return 0
    fi
    # Loud: a pin that does not run is a mistake the operator wants to hear
    # about. Fall through to discovery rather than hard-failing, so a bad pin
    # degrades to "the default was used" and never wedges a hook.
    printf 'resolve_python: HOOK_PYTHON=%s did not answer --version with "Python 3"; ignoring the pin.\n' \
      "$HOOK_PYTHON" >&2
  fi
  for c in python3 python; do
    p="$(command -v "$c" 2>/dev/null)" || continue
    [ -n "$p" ] || continue
    if _probe_python "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}
