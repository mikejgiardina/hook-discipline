#!/bin/bash
# Contract tests for lib/jsonstate.py — the shared JSON state-file helpers.
#
# === What the module has to get right ===
# Two hooks read-modify-write the same registry file. Before this module they
# did it with no lock, so concurrent writers lost each other's updates, and
# their load() answered {} for a file it could not parse, so the next save
# erased every peer. Each half below pins one of those properties from both
# directions:
#
#   L  load: "absent" is {}, and every flavour of "present but unusable" RAISES.
#      L1 is the control for L2-L5 — a load() that raised on everything would
#      pass the raise cases and fail L1.
#   S  save: round-trips and leaves no temp shard behind.
#   C  concurrency: N processes doing locked increments lose nothing. This is
#      the property the lock exists for, measured rather than assumed.
#   K  the lock itself: a live holder makes the waiter time out AFTER waiting
#      and leaves the holder's file alone; a stale one is broken; the lock is
#      released on normal exit and on an exception. K7 (an unremovable stale
#      lockfile) is paired with K4 (an identical, removable one): same age,
#      same holder text, and only removability moves.
#   I  lock_info / break_lock.
#
# Python is inline. Each snippet prints one verdict token, compared by check().
# Run: bash tests/test-jsonstate.sh

set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TESTS_DIR/../lib" && pwd)"
[ -f "$LIB_DIR/jsonstate.py" ] || { echo "FATAL: $LIB_DIR/jsonstate.py not found"; exit 1; }

. "$LIB_DIR/resolve-python.sh"
unset HOOK_PYTHON
PY="$(resolve_python || true)"
[ -n "$PY" ] || { echo "FATAL: python required — the module under test is python"; exit 1; }

# Fixture root sits outside the checkout under test; see tests/lib/fixture-root.sh.
. "$TESTS_DIR/lib/fixture-root.sh"
fixture_root_init jsonstate
P="$FIX/state.json"

pass=0; fail=0; skip=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1))
  else echo "  FAIL  $1 — expected $2, got $3"; fail=$((fail+1)); fi
}

# Run a snippet with the module importable and the state path in JS_P. Paths
# travel as standalone env vars so Git Bash converts them to native form for a
# Windows interpreter. -B keeps bytecode out of the checkout.
jpy() { # <python code>
  JS_LIB="$LIB_DIR" JS_P="$P" "$PY" -X utf8 -B -c "import os, sys
sys.path.insert(0, os.environ['JS_LIB'])
import jsonstate as js
p = os.environ['JS_P']
$1"
}

load_verdict='
try:
    d = js.load(p)
    print("DICT" if d == {} else "DATA")
except js.Corrupt:
    print("CORRUPT")
'

echo "jsonstate.py"

echo "L. load — absent is empty, damaged raises"
rm -f "$P"
check "L1 absent file -> {}" DICT "$(jpy "$load_verdict")"
printf '{"a": 1, "b":' > "$P"
check "L2 truncated JSON -> Corrupt" CORRUPT "$(jpy "$load_verdict")"
printf '[1, 2, 3]' > "$P"
check "L3 a JSON array (not an object) -> Corrupt" CORRUPT "$(jpy "$load_verdict")"
: > "$P"
check "L4 empty file -> Corrupt" CORRUPT "$(jpy "$load_verdict")"
printf '"just a string"' > "$P"
check "L5 a JSON scalar -> Corrupt" CORRUPT "$(jpy "$load_verdict")"
printf '{"a": 1}' > "$P"
check "L6 a valid object loads as data (control for L2-L5)" DATA "$(jpy "$load_verdict")"

echo
echo "S. save — atomic, round-trips"
rm -f "$P"
check "S1 save round-trips" YES "$(jpy '
ok = js.save(p, {"k": [1, 2], "u": "é"})
print("YES" if ok and js.load(p) == {"k": [1, 2], "u": "é"} else "NO")
')"
shards="$(find "$FIX" -name 'state.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
check "S2 no temp shard is left behind" 0 "$shards"
check "S3 save into a missing directory returns False" NO "$(jpy '
print("YES" if js.save(os.path.join(os.path.dirname(p), "no", "such", "dir.json"), {}) else "NO")
')"

echo
echo "C. concurrency — locked increments lose nothing"
rm -f "$P" "$P.lock"
inc='
for _ in range(15):
    with js.locked(p, timeout=30, stale=30):
        d = js.load(p)
        d["n"] = d.get("n", 0) + 1
        js.save(p, d)
'
for _w in 1 2 3 4; do
  jpy "$inc" &
done
wait
check "C1 4 processes x 15 locked increments == 60" 60 "$(jpy '
try:
    print(js.load(p).get("n"))
except js.Corrupt:
    print("CORRUPT")
')"
check "C2 no lockfile is left behind" NO "$([ -e "$P.lock" ] && echo YES || echo NO)"
shards="$(find "$FIX" -name 'state.json.tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
check "C3 no temp shard is left behind" 0 "$shards"

echo
echo "K. the lock"
# K1-K3: a live holder. The lockfile is fresh, so it must not be broken; the
# waiter must actually wait for its timeout, and must leave the holder's file
# exactly as it found it.
rm -f "$P.lock"; printf '4242 1700000000\n' > "$P.lock"
out="$(jpy '
import time
t0 = time.time()
try:
    with js.locked(p, timeout=0.6, stale=30):
        print("ACQUIRED")
except js.LockTimeout:
    print("TIMEOUT %.2f" % (time.time() - t0))
')"
check "K1 a held lock raises LockTimeout" TIMEOUT "${out%% *}"
waited="$(printf '%s' "${out#* }" | awk '{ print ($1 >= 0.5) ? "YES" : "NO" }')"
check "K2 ...after waiting out the timeout (waited ${out#* }s)" YES "$waited"
check "K3 ...and leaves the holder's lockfile untouched" '4242 1700000000' "$(cat "$P.lock" 2>/dev/null)"
rm -f "$P.lock"

# K4: the same lockfile, aged past `stale`. It is broken and the lock acquired.
printf '4242 1700000000\n' > "$P.lock"
check "K4 a stale lockfile is broken" ACQUIRED "$(jpy '
old = 1700000000
os.utime(p + ".lock", (old, old))
try:
    with js.locked(p, timeout=2, stale=30):
        print("ACQUIRED")
except js.LockTimeout:
    print("TIMEOUT")
')"

rm -f "$P.lock"
check "K5 the lock is released on normal exit" NO "$(jpy '
with js.locked(p, timeout=2, stale=30):
    assert os.path.exists(p + ".lock")
print("YES" if os.path.exists(p + ".lock") else "NO")
')"
check "K6 the lock is released when the body raises (and the error propagates)" RAISED-NO "$(jpy '
try:
    with js.locked(p, timeout=2, stale=30):
        raise ValueError("boom")
except ValueError:
    print("RAISED-" + ("YES" if os.path.exists(p + ".lock") else "NO"))
')"

# K7: a stale lockfile that CANNOT be removed. The acquire loop must still
# honour its deadline instead of spinning on the failed break. Windows: a
# read-only lockfile refuses deletion. POSIX: a read-only directory refuses it.
# Both are restored afterwards so cleanup works. The premise is checked first —
# as root, a read-only directory still allows removal, and the case would then
# measure K4 again.
mkdir -p "$FIX/ro"
RO_P="$FIX/ro/state.json"
printf '4242 1700000000\n' > "$RO_P.lock"
out="$(JS_LIB="$LIB_DIR" JS_P="$RO_P" "$PY" -X utf8 -B -c '
import os, stat, sys, time
sys.path.insert(0, os.environ["JS_LIB"])
import jsonstate as js
p = os.environ["JS_P"]
lk = p + ".lock"
d = os.path.dirname(p)
old = 1700000000
os.utime(lk, (old, old))
if os.name == "nt":
    os.chmod(lk, stat.S_IREAD)
    restore = lambda: os.chmod(lk, stat.S_IREAD | stat.S_IWRITE)
else:
    os.chmod(d, 0o555)
    restore = lambda: os.chmod(d, 0o755)
try:
    probe = os.path.join(d, "probe")
    try:
        if os.name == "nt":
            unremovable = not (os.stat(lk).st_mode & stat.S_IWRITE)
        else:
            open(probe, "w").close()
            os.remove(probe)
            unremovable = False
    except OSError:
        unremovable = True
    if not unremovable:
        print("SKIP")
    else:
        # Watchdog: a loop that spins on the failed break never returns, which
        # would hang the suite instead of failing it.
        import threading
        def _spun():
            restore()
            print("SPIN")
            sys.stdout.flush()
            os._exit(3)
        wd = threading.Timer(10, _spun)
        wd.daemon = True
        wd.start()
        t0 = time.time()
        try:
            with js.locked(p, timeout=0.6, stale=30):
                print("ACQUIRED")
        except js.LockTimeout:
            print("TIMEOUT %.2f" % (time.time() - t0))
        wd.cancel()
finally:
    restore()
' 2>&1)"
case "$out" in
  SKIP*)
    echo "  SKIP  K7 unremovable stale lockfile — cannot make it unremovable here (running as root?)"; skip=$((skip+1))
    echo "  SKIP  K8 ...returns within the deadline — premise unavailable"; skip=$((skip+1))
    ;;
  *)
    check "K7 an unremovable stale lockfile ends in LockTimeout, not a spin" TIMEOUT "${out%% *}"
    inbound="$(printf '%s' "${out#* }" | awk '{ print ($1 != "" && $1 < 3.0) ? "YES" : "NO" }')"
    check "K8 ...and returns within the deadline (took ${out#* }s, limit 3s)" YES "$inbound"
    ;;
esac
chmod -R u+w "$FIX/ro" 2>/dev/null

echo
echo "I. lock_info / break_lock"
rm -f "$P.lock"
check "I1 lock_info with no lockfile -> (None, '')" "None|" "$(jpy '
age, holder = js.lock_info(p)
print("%s|%s" % (age, holder))
')"
check "I2 lock_info reports the holder written by locked()" YES "$(jpy '
with js.locked(p, timeout=2, stale=30):
    age, holder = js.lock_info(p)
print("YES" if age is not None and age < 5 and holder.split()[0] == str(os.getpid()) else "NO %r %r" % (age, holder))
')"
printf '4242 1700000000\n' > "$P.lock"
check "I3 break_lock removes a lockfile regardless of age" True "$(jpy 'print(js.break_lock(p))')"
check "I4 ...and it is gone" NO "$([ -e "$P.lock" ] && echo YES || echo NO)"
check "I5 break_lock with no lockfile -> False" False "$(jpy 'print(js.break_lock(p))')"

echo "----------------------------------------"
echo "passed: $pass   failed: $fail   skipped: $skip"
[ "$fail" -eq 0 ] || exit 1
