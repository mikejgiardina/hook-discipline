"""jsonstate.py — shared helpers for a JSON state file that several hooks write.
IMPORT it, don't run it.

=== Why this exists ===
The live-session registry has more than one writer: session-registry.sh on
every SessionStart, Stop and SessionEnd, and worktree-guard.sh on every git
command. Each writer used to do load -> modify -> atomic replace with nothing
serialising the three steps. The replace was atomic; the cycle was not. Two
writers that loaded the same version each wrote back their own change, and the
second replace erased the first. Last writer wins, silently.

The second defect sat inside load(). It returned {} on ANY error, so a file that
existed but could not be parsed read exactly like a file that did not exist.
The next save then wrote a registry holding only the current session, and every
peer vanished from it. Nothing said so: the observable result was the ABSENCE
of a warning, which is also what a healthy registry with no peers produces.

So this module separates the two cases and serialises the cycle:

  * "absent" and "unreadable" are different answers, and only the first is {}.
  * a read-modify-write runs under an exclusive lockfile.

=== Contract ===
    load(path)        -> dict. {} ONLY when the file does not exist. A file that
                         exists but cannot be read, does not parse, or is not a
                         JSON object raises Corrupt. The caller decides what to
                         do with a damaged file; silently replacing it is not a
                         decision this module makes on anyone's behalf.
    save(path, d)     -> bool. Writes a temp file beside `path`, then
                         os.replace (atomic on one filesystem). False on
                         failure, with the temp file removed.
    locked(path, timeout=10, stale=30)
                      -> context manager holding `<path>.lock`.
                         The lockfile is created with O_CREAT|O_EXCL, which
                         behaves the same on Linux, macOS and Windows (no fcntl,
                         no msvcrt). A lockfile older than `stale` seconds is
                         treated as left by a holder that died and is removed.
                         Waiting past `timeout` raises LockTimeout.
    lock_info(path)   -> (age_seconds, holder_text) for `<path>.lock`, or
                         (None, "") when there is no lockfile.
    break_lock(path)  -> bool. Removes `<path>.lock` regardless of age, for an
                         operator who knows the holder is gone.

=== Windows ===
Windows opens files without FILE_SHARE_DELETE by default, so a reader holding
the state file open makes os.replace and os.remove fail, and a replace in flight
makes a reader fail. Both surface as PermissionError and clear within a few
milliseconds. _retry absorbs that window. Without it, a concurrent read and
write on Windows is a spurious Corrupt or a lost save.

A lockfile that is being deleted also reports PermissionError to a second
O_EXCL open, so the acquire loop treats that as "busy", not as an error.

=== The stale break must not spin ===
A stale lockfile that cannot be removed (read-only file, read-only directory,
held open elsewhere) must not turn the acquire loop into a busy-wait that
ignores its own deadline. A failed removal falls through to the same deadline
check as an ordinary held lock, so `timeout` bounds every path out of locked().
"""
import contextlib
import json
import os
import time


class Corrupt(Exception):
    """The state file exists but is unreadable, unparseable, or not an object."""


class LockTimeout(Exception):
    """The lockfile could not be acquired within the timeout."""


def _retry(fn, tries=6, pause=0.02):
    """Call fn, retrying a transient Windows sharing violation (PermissionError)."""
    for i in range(tries):
        try:
            return fn()
        except PermissionError:
            if i == tries - 1:
                raise
            time.sleep(pause)


def load(path):
    def _read():
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    try:
        d = _retry(_read)
    except FileNotFoundError:
        return {}
    except Exception as e:  # unreadable, truncated, empty, not JSON
        raise Corrupt("%s: %s" % (path, e.__class__.__name__))
    if not isinstance(d, dict):
        raise Corrupt("%s: top level is %s, not an object" % (path, type(d).__name__))
    return d


def save(path, d):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(d, f)
        _retry(lambda: os.replace(tmp, path))
        return True
    except Exception:
        try:
            os.remove(tmp)
        except Exception:
            pass
        return False


@contextlib.contextmanager
def locked(path, timeout=10.0, stale=30.0, poll=0.05):
    lk = path + ".lock"
    deadline = time.time() + timeout
    fd = None
    while fd is None:
        try:
            fd = os.open(lk, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            try:
                if time.time() - os.path.getmtime(lk) > stale:
                    os.remove(lk)  # the holder died inside its section
                    continue
            except FileNotFoundError:
                continue  # released between the open and the stat: retry now
            except OSError:
                pass  # cannot break it; wait out the deadline like a live holder
            if time.time() >= deadline:
                raise LockTimeout(lk)
            time.sleep(poll)
        except PermissionError:
            # Windows: a lockfile mid-deletion answers a sharing violation.
            if time.time() >= deadline:
                raise LockTimeout(lk)
            time.sleep(poll)
    try:
        os.write(fd, ("%d %d\n" % (os.getpid(), int(time.time()))).encode())
        os.close(fd)
        yield
    finally:
        try:
            _retry(lambda: os.remove(lk))
        except OSError:
            pass


def lock_info(path):
    """(age_seconds, holder_text) of <path>.lock, or (None, '') when absent."""
    lk = path + ".lock"
    try:
        age = int(time.time() - os.path.getmtime(lk))
        with open(lk, encoding="utf-8", errors="replace") as f:
            holder = f.read().strip()[:60]
        return age, holder
    except OSError:
        return None, ""


def break_lock(path):
    """Remove <path>.lock regardless of age. True if a lockfile was removed."""
    try:
        _retry(lambda: os.remove(path + ".lock"))
        return True
    except OSError:
        return False
