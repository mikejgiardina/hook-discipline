#!/usr/bin/env bash
# resolve-python.sh — shared interpreter resolver. SOURCE it, don't run it.
#
# `command -v` proves a NAME RESOLVES, not that it RUNS. Windows 11 ships an
# App-Execution-Alias stub at %LOCALAPPDATA%\Microsoft\WindowsApps\python3.exe
# that prints a Microsoft Store advertisement and exits 49, while real Python
# ships python.exe and no python3.exe, so `command -v python3 || command -v
# python` yields a non-empty, non-functional PY. The same shape applies to bash:
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
# === Contract ===
#   resolve_python   -> echoes an interpreter that answered `--version` with
#                       "Python 3", and returns 0.
#                       Echoes NOTHING and returns 1 when none does.
#
# Callers keep their own fail-open/fail-closed posture by wrapping the call:
#
#   PY="$(resolve_python || echo python)"   # last-resort literal (advisory hooks)
#   PY="$(resolve_python || true)"          # then test [ -z "$PY" ] and decide
#
# === Escape hatch ===
# HOOK_PYTHON=/path/to/python pins an interpreter and skips discovery. It is
# still probed — a pin that does not run is a configuration error worth failing
# on, not a way to smuggle a dead interpreter past the check.
#
# === Cost and cache ===
# A probe is a process launch, and the Windows Store alias takes about a second
# to answer (several under load). So a clean discovery is cached in one file, and
# anything that could change the answer forces a fresh probe.
#
#   RESOLVE_PYTHON_CACHE       the file; unset means
#                              ${TMPDIR:-/tmp}/resolve-python-$USER.cache,
#                              empty disables the cache
#   RESOLVE_PYTHON_CACHE_TTL   entry lifetime in seconds (default 600)
#
# A hit needs all of: the same key (the pin, PATH, and the file each candidate
# name resolves to, so a new interpreter shadowing the cached one misses); the
# cached interpreter still executable and not newer than the cache (an upgrade,
# reinstall or re-pointed alias); a cache file the caller owns; and an entry
# younger than the TTL, which bounds how long an interpreter that broke without
# any file changing can be returned. Only clean discoveries are stored, so a dead
# pin warns on every call. A hit forks nothing on bash >= 4.2 (3.2: one `date`).
#
# The cache does not excuse resolving above a hook's scope filter: a miss still
# pays every probe, so pre-filter first and resolve only where python is used.

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

# Cache helpers. They set globals rather than echo, because every $(...) is a
# fork and the point of a hit is to spawn nothing.
_rp_now() { # -> _RP_NOW, epoch seconds
  if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    printf -v _RP_NOW '%(%s)T' -1
  else
    _RP_NOW="$(date +%s)"
  fi
}

# First executable "$dir/$1" on PATH, walked without a fork. It only has to
# change whenever the real lookup's answer could, which makes it a key component,
# not a resolver. An empty PATH entry means the current directory.
_rp_first_on_path() { # $1=name -> _RP_FOUND (empty when absent)
  local rest="$PATH:" d
  _RP_FOUND=""
  while [ -n "$rest" ]; do
    d="${rest%%:*}"; rest="${rest#*:}"
    [ -n "$d" ] || d=.
    if [ -f "$d/$1" ] && [ -x "$d/$1" ]; then _RP_FOUND="$d/$1"; return 0; fi
  done
}

# File layout: key, interpreter, epoch written, one per line.
_rp_cache_get() { # $1=key -> prints the cached interpreter; 0 on a valid hit
  local ck="" cp="" ct=""
  [ -n "$_RP_CACHE" ] && [ -f "$_RP_CACHE" ] && ! [ -L "$_RP_CACHE" ] && [ -O "$_RP_CACHE" ] || return 1
  { IFS= read -r ck && IFS= read -r cp && IFS= read -r ct; } 2>/dev/null < "$_RP_CACHE" || return 1
  [ "$ck" = "$1" ] && [ -n "$cp" ] && [ -f "$cp" ] && [ -x "$cp" ] && ! [ "$cp" -nt "$_RP_CACHE" ] || return 1
  case "$ct" in ''|*[!0-9]*) return 1 ;; esac
  _rp_now
  ct=$(( _RP_NOW - 10#$ct ))
  [ "$ct" -ge 0 ] && [ "$ct" -lt "$_RP_TTL" ] || return 1
  printf '%s' "$cp"
}

_rp_cache_put() { # $1=key $2=interpreter; never fails the caller
  [ -n "$_RP_CACHE" ] && ! [ -d "$_RP_CACHE" ] && ! [ -L "$_RP_CACHE" ] || return 0
  local t="$_RP_CACHE.$$.tmp"
  _rp_now
  # noclobber: never write through something already sitting at the temp name.
  if ( set -C; printf '%s\n%s\n%s\n' "$1" "$2" "$_RP_NOW" > "$t" ) 2>/dev/null; then
    mv -f "$t" "$_RP_CACHE" 2>/dev/null || rm -f "$t" 2>/dev/null || :
  fi
  return 0
}

resolve_python() {
  local c p p3 key pin_ok=1
  _RP_CACHE="${RESOLVE_PYTHON_CACHE-${TMPDIR:-/tmp}/resolve-python-${USER:-${USERNAME:-user}}.cache}"
  _RP_TTL="${RESOLVE_PYTHON_CACHE_TTL:-600}"
  case "$_RP_TTL" in ''|*[!0-9]*) _RP_TTL=600 ;; esac
  _RP_TTL=$(( 10#$_RP_TTL ))
  _rp_first_on_path python3; p3="$_RP_FOUND"
  _rp_first_on_path python
  key="${HOOK_PYTHON:-}|$PATH|$p3|$_RP_FOUND"
  _rp_cache_get "$key" && return 0

  if [ -n "${HOOK_PYTHON:-}" ]; then
    if _probe_python "$HOOK_PYTHON"; then
      _rp_cache_put "$key" "$HOOK_PYTHON"
      printf '%s' "$HOOK_PYTHON"
      return 0
    fi
    pin_ok=0
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
      [ "$pin_ok" -eq 0 ] || _rp_cache_put "$key" "$p"
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}
