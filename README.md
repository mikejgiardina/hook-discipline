# hook-discipline

Lifecycle hooks for coding agents, and the test pattern that keeps them honest.

These are working hooks extracted from a private automation layer, together with
the suite that tests them. They run on [Claude Code](https://claude.com/claude-code)
lifecycle events, but almost nothing here is specific to that: they are shell
scripts that read a JSON payload on stdin and decide whether to allow, warn, or
deny. The reasoning transfers to any agent runtime, and to git hooks generally.

The reason this repo exists is not the hooks. It is a single problem that turns
out to be much harder than it looks:

**A check that never ran and a check that found nothing produce identical output.**

Everything below follows from taking that seriously.

---

## What's in here

Each line is the claim, not just the topic — so this doubles as the summary if
you read nothing else. The sections themselves go into why, with the incidents
that produced them.

**The argument**

- [The three-state exit contract](#the-three-state-exit-contract) — "could not
  check" has to be a *state*, not an absence. A hook that was never installed
  reports exactly what a clean run reports.
- [Fail-open, fail-closed, and fail-silent are three decisions, not two](#fail-open-fail-closed-and-fail-silent-are-three-decisions-not-two)
  — fail-silent is orthogonal to the other two, and it is almost always wrong.
- [Know what your gate actually asserts](#know-what-your-gate-actually-asserts)
  — "the term scan passed" means no term leaked. It does not mean the numbers
  are right.
- [A guard that fires on prose is worse than no guard](#a-guard-that-fires-on-prose-is-worse-than-no-guard)
  — false-positive rate scales with how often you write *about* the thing you
  guard, and the override reflex is the real cost.

**Testing checks that are silent by design**

- [A passing test is not evidence that the check ran](#a-passing-test-is-not-evidence-that-the-check-ran)
  — every quiet case is paired with a control. Verify it yourself: neuter a hook
  and watch which cases survive.
- [A skipped case is a case that did not run](#a-skipped-case-is-a-case-that-did-not-run)
  and [the floor that makes counting mean something](#the-floor-a-suite-has-to-account-for-its-cases)
- [Tests that pass without ever reaching their subject](#tests-that-pass-without-ever-reaching-their-subject)
  — fixtures inside the tree under test, and a suite that ran against a real
  production system while reporting green.
- [An escape hatch can route around the test's own interposition](#an-escape-hatch-can-route-around-the-tests-own-interposition)
- [When you fix an instance, enumerate the pair](#when-you-fix-an-instance-enumerate-the-pair)
  — the hardest defect to see is a *missing* line: a fix that landed on one of
  two identical surfaces.

**Portability, and the shell**

- [Cross-platform, because silence is portable and shell is not](#cross-platform-because-silence-is-portable-and-shell-is-not)
  — `command -v` proves a name resolves, not that it runs; plus the Windows and
  macOS specifics that cost the most.
- [The shell mechanic that kills hooks quietly](#the-shell-mechanic-that-kills-hooks-quietly)
  — `set -euo pipefail` + a no-match `grep` kills the script on the *assignment*
  line.

**The code**

- [What's here](#whats-here) — file-by-file map.
- [`tools/closing-refs.py` is useful on its own](#toolsclosing-refspy-is-useful-on-its-own)
  — GitHub silently drops several closing-keyword forms that look correct.
- [A sibling failure this repo documents but does not check](#a-sibling-failure-this-repo-documents-but-does-not-check)
  — verify the state you wanted, not the success of the operation you ran. And
  [why the detection is the interesting half](#the-detection-is-the-interesting-half).
- [Using these](#using-these) · [why `term-scan.sh` ships without its registry](#term-scansh-ships-without-its-registry-on-purpose)
- [Longer write-ups](#longer-write-ups) · [Status and scope](#status-and-scope) · [License](#license)

Sections are self-contained; skipping around costs nothing.

---

## The three-state exit contract

Most checks are written as if they have two outcomes: pass or fail. That model
is missing the state that actually causes incidents.

| state | meaning | what the operator should see |
|---|---|---|
| **clean** | ran to completion, found nothing | silence |
| **violations found** | ran to completion, found something | the findings |
| **could not check** | never reached a verdict | *an explicit statement that it did not run* |

The third state is the one that gets collapsed into the first, and collapsing it
is how a safety check dies without anybody noticing. A scanner whose scope filter
matches nothing, whose interpreter is broken, or whose input parsing silently
returns empty, prints exactly what a clean run prints: nothing at all.

The sharpest instance is not a bug in any hook. It is the wiring.

A term scanner fired **zero times** across every edit that produced a set of
public web pages. The scope globs were not the cause — the relevant one matched,
and the hook lowercases the path before matching. The cause was that the session
was rooted in a directory where the hook file *did not exist*. Hooks are wired as

```
bash "$CLAUDE_PROJECT_DIR/hooks/<name>.sh" 2>/dev/null || true
```

and when that variable resolves somewhere without a `hooks/` directory, every
hook becomes a missing file whose non-zero exit is swallowed by `|| true`.

So the check did not report clean. It did not report violations. It did not
report could-not-check. **It reported nothing, because it was never there** — and
the wiring made absence and success byte-identical.

That is why the third state has to be a *state* rather than an absence. A check
that can only express two outcomes has no way to say "I was not running," which
is the one thing you most need to hear.

Concrete instances from this layer, all of them real:

- A family of hooks read the edited file's path from an environment variable that
  was never part of the runtime's contract. It expanded empty, every one of them
  exited at its second line, and they stayed that way for months. Among them was
  the hook whose entire job was scanning files before publication. See
  [`lib/payload.sh`](lib/payload.sh).
- A scope filter said `grant/` where the live directory was `grants/`. One
  character. Total coverage loss on an outward-facing document set, reporting
  success on every write. See [`hooks/term-scan.sh`](hooks/term-scan.sh).
- A term registry declared canonical terms *and aliases*. The scanner extracted
  only the canonical field. It advertised coverage it did not implement — and
  aliases are the phrasing prose actually reaches for.
- An interpreter resolver accepted `command -v python3` as proof that python3
  runs. On Windows it resolves an App-Execution-Alias stub that prints a Store
  advertisement and exits 49. See [`lib/resolve-python.sh`](lib/resolve-python.sh).

None of these surfaced on their own. Every one was found by going looking.

---

## Fail-open, fail-closed, and fail-silent are three decisions, not two

Fail-open versus fail-closed is a familiar axis: when a check cannot reach a
verdict, does it allow or deny? The answer depends on what is on the other side.

The axis that gets missed is orthogonal to it. **Fail-silent is a separate
decision, and it is almost always the wrong one** — including, and especially,
in a fail-open check.

A fail-open check that announces its failure is a degraded control. A fail-open
check that says nothing is indistinguishable from a working one, which means it
will not be repaired, which means it is not a control at all. It is a comment.

So this layer uses three postures:

**1. Advisory, fail-open.** The default. Cannot evaluate means allow. A guard
that blocks work because a toolchain hiccupped is worse than the problem it
solves. See [`hooks/worktree-guard.sh`](hooks/worktree-guard.sh).

**2. Fail-closed, narrow scope.** Every "cannot evaluate" branch denies, because
what is on the other side is irreversible — a leaked credential, a permanent
disclosure. Scope stays deliberately narrow so that a toolchain problem cannot
wedge unrelated work. See [`hooks/secrets-scan.sh`](hooks/secrets-scan.sh).

The narrowness is not fastidiousness. When the interpreter resolver broke, the
fail-closed scanner correctly denied — and because it pre-filtered on the
substring `commit`, it also denied every shell command that merely *contained*
that word, including the ones someone would reach for to diagnose it. Blast
radius is a design parameter of a fail-closed check.

**3. Fail-open, but loud.** Deny only on a positive determination; every
uncertainty allows *and says so on stderr*. Right when the harm is recoverable
and blocking would be disproportionate. See
[`hooks/skip-ci-guard.sh`](hooks/skip-ci-guard.sh).

---

## Know what your gate actually asserts

A check that passes tells you one specific thing. It is very easy to read it as
telling you a much larger thing, and nothing in the output corrects you.

> **"The term scan passed" means no proprietary term leaked. It does not mean the
> numbers are sound.**

Those are two different assertions and only one of them was made. A fixed-string
scanner validates *vocabulary*. It cannot see a figure caption contradicting its
own chart, a claimed floor that is really a residual of two approximations, or a
percentage that does not reproduce from the operands printed beside it. Every one
of those is a real defect found by a human reviewer on a document that passed the
automated gate cleanly — correctly, because none of them is a vocabulary problem.

A green gate whose scope the reader misjudges is worse than no gate, because it
manufactures exactly the confidence the reader should not have. So say what the
check covers, in the output, where someone reading a pass will see it — which is
why [`hooks/term-scan.sh`](hooks/term-scan.sh) prints "this is an early warning,
not clearance" rather than letting silence imply more than it earned.

## A passing test is not evidence that the check ran

This is the part worth the most, and it is why the test suite is roughly half
this repository.

Most of these hooks produce **no output in the success case**, by design — a
check that prints on every write gets ignored. But that makes the observable
result of "working correctly" byte-identical to the observable result of
"never invoked", "crashed on line 2", "scope filter matched nothing", or
"deleted last week".

A suite full of assertions that the hook stayed quiet will pass, in full, against
a hook replaced with `exit 0`.

**So every quiet case here is paired with a control that makes the same wiring
fire**, usually by changing exactly one variable — the directory, not the
content; the registry path, not the file. The pair says *silent because
excluded*, where the single assertion could only say *silent*.

The discipline is verifiable, and you should verify it rather than trust this
paragraph. Neuter a hook and re-run its suite:

```bash
cp hooks/term-scan.sh /tmp/backup && printf '#!/usr/bin/env bash\nexit 0\n' > hooks/term-scan.sh
bash tests/test-term-scan.sh    # 9 of 17 fail; every quiet case still passes
cp /tmp/backup hooks/term-scan.sh
```

The quiet cases passing against a dead hook is not a flaw in the suite. It is the
demonstration. Those cases were never capable of detecting the failure, and no
amount of adding more of them would help.

### A skipped case is a case that did not run

Some cases here genuinely cannot run everywhere: a Windows-only path form, a
python-free `PATH` that cannot be constructed on a given box. Skipping those is
correct. Being unable to *see* that they skipped is not.

Before this was fixed, a skip incremented no counter and printed nothing the
runner noticed. A suite whose subject was absent on the current platform reported
the same `ok` as one that exercised everything — the only difference being an
assertion total that moved, which nobody reads. The MSYS path cases skip on Linux
and macOS, which is two of the three CI legs.

So `run-all.sh` counts skips, prints them per file, and lists them in the summary
on every green run. **Honest limitation:** it reports skips per run, so it cannot
tell you a case skipped on *every* platform and therefore ran nowhere. Reading
the three CI legs together is still a manual step.

### The floor: a suite has to account for its cases

Counting is not enough on its own. A suite that quietly stops running half its
cases still exits 0, still prints `ok`, and differs only by a number nobody has
anything to compare against.

[`tests/suite-floors.tsv`](tests/suite-floors.tsv) gives it something. The
runner enforces, per suite:

```
assertions_made + cases_explicitly_skipped  >=  measured floor
```

The `+ skipped` term is the design. A case that genuinely cannot run here — no
`cygpath`, no python-free `PATH`, not a drive-form path — is legitimate; it just
has to *say so*, and is then visible rather than absent. And **a bare `SKIP`
counts as exactly one case**, so a block-level skip standing in for three
assertions fails the floor. The fix is to emit one `SKIP` per skipped case, which
is also the more honest thing to print.

This is not hypothetical. It was added after a suite reported **44 cases on two
platforms and 25 on the third, in a fully green run** — a GNU-only `sed`
construct emitted nothing under BSD sed, so nineteen assertions vanished while
the corpus behind them still executed correctly. Only their evidence was lost,
and nothing was in a position to notice.

That bug also broke this repository's own stated portability rule, which says in
as many words: no GNU-only `sed` without a fallback. The rule was written down,
was correct, and was still violated — which is the argument for a check rather
than a convention.

### Tests that pass without ever reaching their subject

The stronger version of the problem: a test can be *green for years* while never
once exercising what it claims to.

Several suites here allocated their fixture directory **inside the checkout under
test**. In one, the hook resolved a repository from its payload, one candidate
was the payload's `cwd`, and the fixture root pointed it at the developer's real
repository. That case evaluated real unpushed commits — and passed, because the
range happened to be empty. It had never reached its own subject.

In the others the leak was shielded, but shielded *by accident*: their targets
were spoofed repositories, so the resolution loop stopped before reaching `cwd`.
Nothing enforced that. Nobody had chosen it.

Worse was available. A suite that interposes a fake CLI on `PATH` will, if the
interposition silently fails, run the **real** CLI — and in one case issued a
live mutation against a production project board while twelve assertions
reported green.

[`tests/lib/fixture-root.sh`](tests/lib/fixture-root.sh) makes the safe
allocation the default, and exposes `fixture_root_scope` so a suite can *assert*
its fixtures are outside the tree under test. A comment saying "keep this
outside the repo" is a request. An assertion is enforcement.

### An escape hatch can route around the test's own interposition

Most of [`tests/test-resolve-python.sh`](tests/test-resolve-python.sh) works by
putting a fake interpreter on `PATH` and asserting which one gets picked. That
entire technique is silently defeated by an ambient `HOOK_PYTHON`, because the
pin is honoured *before* any `PATH` lookup — the stubs are never consulted and
every case measures the pin instead, passing throughout.

The same shape, in a sibling suite, is what let an interposed CLI shim be
bypassed so the real CLI ran against production. The fix is one line, `unset`,
plus an assertion that it is unset — because the `unset` alone is a request a
future edit can quietly undo, and a documented escape hatch is exactly the kind
of feature nobody remembers when writing a test three months later.

### When you fix an instance, enumerate the pair

The defect that is hardest to see is not a wrong line. It is a *missing* one —
a fix that landed on one of two identical surfaces.

Both of the findings that survived into a second review pass of this repository
had that shape, and neither was reachable by any mechanical scan:

- A cleanup sweep replaced a scale figure in a hook's header, and the test file
  documenting the *same* incident kept the original number. One half of a pair
  fixed, one half not. No term scanner catches it, because it is prose rather
  than vocabulary; it was only findable by reading the two files against each
  other.
- A missing-dependency branch was added to two sibling hooks. One got a test for
  it, the other did not — and the untested one sat in a repository whose entire
  argument is that untested checks fail silently.

In both cases every individual file was defensible on its own. The defect existed
only in the relationship between two of them, as an absence.

So when a fix goes in, the question is not "is this file right now?" but "what
else has this same shape, and did the fix reach it?" A grep for the thing you
just fixed is cheap. A grep for the thing you fixed *minus* the places you fixed
it is what actually finds the second one.

---

## Cross-platform, because silence is portable and shell is not

These run on Windows (Git Bash), macOS, and Linux. A hook that assumes one
platform does not error on the others — it no-ops, quietly, which puts it right
back in the failure mode above. The findings that cost the most:

- **`command -v` proves a name RESOLVES, not that it RUNS.** On Windows the two
  come apart routinely. `python3` resolves an App-Execution-Alias stub that exits
  49; `bash` can resolve a WSL alias with no distro installed, or
  `C:\WINDOWS\system32\bash.exe` installed silently by Docker Desktop — and
  `system32` is on the machine PATH, so it outranks `Git\bin` no matter where you
  put `Git\bin` in the user PATH. Probe every candidate before accepting it.
- **`mktemp -d` on Git Bash returns a path half the toolchain cannot use.**
  `/tmp/tmp.XXXX` is invisible to Windows Python's path translation, which
  rewrites `/x/...` and `/cygdrive/x/...` and nothing else. The obvious fix
  (`cygpath -m`, giving `C:/...`) breaks bash's own PATH lookup, so an interposed
  shim silently vanishes. The form that satisfies both is drive-lettered MSYS,
  `/C/Users/...`.
- **GNU grep 3.0 as shipped with Git for Windows aborts on `-i -F` combined.**
  Case-fold the haystack and the needle separately with `tr`.
- **Stock macOS has no `timeout`** and ships bash 3.2 — no `declare -A`, no
  `mapfile`, no `${v,,}`. BSD `grep` has no `-oP`.
- **A `timeout` on PATH is not necessarily GNU's.** Windows ships
  `System32\timeout.exe`, which prints "Invalid syntax" and exits 1 without
  touching stdin. A payload read written as `$(timeout 2 cat || echo "")` turns
  that into an empty payload, and every guard reads empty as "allow". Treat any
  exit other than 0 or 124 as "timeout did not run" and read stdin directly;
  `tests/test-timeout-fallback.sh` pins every read site.
- **Fork cost is the budget on Git Bash.** A loop that forks a few processes per
  registry term is invisible on Linux and adds up quickly per file on a
  loaded Windows box, enough for hooks that fire on every write to pile up. Scan
  all terms in one `awk` pass; `term-scan.sh` does.
- **LF line endings**, enforced via `.gitattributes`. A Windows checkout shipping
  CRLF gives `bad interpreter: ...^M` on a Mac.

---

## The shell mechanic that kills hooks quietly

Worth stating on its own, because it accounts for more dead hooks here than any
other single cause:

```bash
set -euo pipefail
FILE="$(printf '%s' "$1" | grep -oE '"file_path"...' | sed -E '...')"
```

A no-match `grep` exits 1. `pipefail` promotes that to the pipeline's status.
`errexit` then kills the script **on the assignment line** — not at the point of
use. The hook dies before doing anything, exits non-zero into a wrapper that
discards exit codes, and goes silent.

A payload with no `file_path` is *normal*, not an error. That is why the trailing
`|| true` in [`lib/payload.sh`](lib/payload.sh) is load-bearing rather than
defensive clutter.

---

## A guard that fires on prose is worse than no guard

A check that matches dangerous commands has to distinguish a command from a
sentence *about* a command. That sounds like a rounding error until you notice
what drives its false-positive rate: **how often you write about the thing you
guard.** In a repository whose purpose is governing dangerous commands, that is
constantly — commit messages, changelog entries, PR bodies written with
`--body "$(cat <<'EOF' ... EOF)"`, and README files like this one.

The consequence is not noise. The operator learns the guard cries wolf and
reaches for the override reflexively, and at that point the guard is worse than
absent, because it still *appears* to protect the operation.

[`lib/cmdparse.py`](lib/cmdparse.py) handles both halves — stripping heredoc
bodies, and anchoring verbs to positions where a command can actually start.
Backtick is deliberately excluded as a command prefix: a verb after a backtick is
overwhelmingly a markdown code span.

It is a shared module rather than a copied function for a specific reason. Two
sibling guards here once carried hand-copies of this logic; one got hardened, the
other did not, and the drifted one eventually blocked a call whose heredoc
contained a destructive verb *as a string being written into a deny-list*. It
failed closed, correctly by its own logic, on a command that did nothing of the
kind.

## What's here

```
lib/resolve-python.sh      interpreter resolution that probes before accepting
lib/payload.sh             stdin payload reader; the || true that keeps hooks alive
lib/cmdparse.py            heredoc stripping, quote-aware command anchoring, git globals, MSYS paths

hooks/secrets-scan.sh      fail-closed: blocks commits staging credentials
hooks/skip-ci-guard.sh     fail-open-but-loud: keeps CI-skip markers off feature branches
hooks/worktree-guard.sh    advisory: guards tree-mutating git ops on a dirty tree
hooks/session-registry.sh  tracks concurrent agent sessions sharing one working tree
hooks/term-scan.sh         registry-driven term scanner (registry NOT included — see below)

tools/closing-refs.py      extracts issue-closing directives from a PR body; --self-test

tests/run-all.sh           runs every suite; derives wiring coverage from settings
tests/lib/fixture-root.sh  fixture allocation outside the checkout under test
tests/test-*.sh            one suite per hook, quiet cases paired with controls

examples/settings.json     wiring example
examples/terms.example.json  schema for term-scan, with fictional entries
```

### `tools/closing-refs.py` is useful on its own

GitHub's issue linker silently drops several forms that look correct to a human:

- `Closes #120, #121` closes only **#120**. The keyword must be repeated.
- Closing keywords in a pull request **title** do nothing. The linker reads the
  description and commit messages.
- `Closes shorthand#123`, where `shorthand` is a project's own prose convention
  rather than a real `owner/repo`, resolves to nothing at all.

Each merges cleanly, reports success, and closes nothing.

The tool extracts and classifies directives; it deliberately **does not decide
that anything should be closed.** A retrospective sweep of several hundred merged
pull requests measured a naive proximity regex at roughly a **75% false-positive
rate**, and the false positives were not near-misses — they included a PR whose
body said the change did *not* close an issue, which a proximity matcher would
have closed anyway. Reading real issue state after a merge has no false-positive
class, because it is not guessing at intent.

```bash
python tools/closing-refs.py --self-test
```

### A sibling failure this repo documents but does not check

Same family, worth knowing, and deliberately *not* shipped as a check here.

A pull request was squash-merged. Further commits were then pushed to that same
branch. They landed on a closed PR and were silently never published.

Nothing failed. The merge reported success, and it had merged. The push reported
success, and it had pushed. The branch existed; the commits existed; the content
simply was not in the merge. Every component returned exactly the right answer to
the question it was asked, and the outcome was silently nothing. The question
nobody asked was *"is the content I pushed actually on the default branch?"* —
which is a different question from *"did the push succeed?"*

It is not an isolated shape. Two more from the same family, both on ordinary git
operations behaving exactly as documented:

- **A merge with `--delete-branch` removed the base branch of a stacked pull
  request.** The forge closed that PR automatically. No notification, and three
  independent recovery paths were blocked at once — no retargeting a closed PR,
  no reopening it without its base, and a publish gate correctly fail-closing on
  a branch recreated at an already-merged commit.
- **A push to a just-merged, just-deleted branch silently created it fresh** at a
  stale base, rather than updating anything.

So the rule generalises past merges: **a successful operation can invalidate work
that is not part of it.** The merge succeeds, the verification confirms it, the
branch deletion does precisely what was asked — and something outside the
transaction is now broken, with nothing responsible for noticing.

### The detection is the interesting half

In every one of these, the evidence was on screen and was not an error.

The second case announced itself as `* [new branch]` in the push output. That is
not a warning. It is git accurately reporting what it did. The defect is visible
only if you knew what you expected it to say instead — an *update* to an existing
branch — and noticed that it said something else.

That is the three-state contract again, one layer out. The information was
present; nothing was structured to make its absence loud. A check earns its keep
by knowing what the expected output was, not by scanning for the word "error".

The general rule: **verify the state you wanted, not the success of the operation
you ran.** `closing-refs.py` exists because of the same gap one level over — a
merge that reports success while closing none of the issues it names.

It is not shipped as a check because a real one needs network access and a live
forge, and every test in this repository is hermetic. An untested check is the
precise failure this repository is about, so adding one here to look thorough
would be self-refuting. Documented instead, honestly, as a shape to watch for.

---

## Using these

Nothing here needs to be adopted wholesale. Take a hook, take the payload reader,
or take only the test pattern.

```bash
git clone https://github.com/<owner>/hook-discipline
cd hook-discipline
bash tests/run-all.sh
```

To wire a hook into Claude Code, see [`examples/settings.json`](examples/settings.json).
Invoke hooks via `$CLAUDE_PROJECT_DIR` rather than an absolute path, and derive
any internal path from `BASH_SOURCE`:

```bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

### `term-scan.sh` ships without its registry, on purpose

The scanner is here. The list of terms is not, and will not be.

A registry of terms you do not want published is itself a document describing
what you consider sensitive. Publishing the list to protect the list is
self-defeating. [`examples/terms.example.json`](examples/terms.example.json)
gives the schema with fictional entries so the hook and its test run out of the
box; point `HOOK_TERM_REGISTRY` at your own private file.

This generalises past term scanning. The reusable artifact is nearly always the
mechanism, not the data it operates on — and separating them at the file boundary
is what makes the mechanism publishable at all.

---

## Longer write-ups

Two case studies cover the design decisions in more depth than a README should:

- [Automation](https://mike-giardina.netlify.app/automation/) — how the layer is
  structured and what each hook is for
- [Enforcement](https://mike-giardina.netlify.app/enforcement/) — the failure
  modes above, in detail, including the incidents

---

## Status and scope

This is a **curated extraction**, not a mirror. The private layer it comes from
has considerably more hooks; the ones tied to a specific project's board,
release process, or repository topology are not here, because they would be
neither useful nor comprehensible outside it.

Not affiliated with or endorsed by Anthropic.

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
