# Ownership-fence consumer (gh-reaper side)

gh-reaper removes worktrees. When a repository's Git common directory is
*fenced*, a worktree may still belong to an operation that has not finished, and
removing it is not gh-reaper's call to make alone.

This file describes what gh-reaper does about that. The authoritative contract
is owned by the producer — `gh-reaper-sweep`,
`skills/gh-reaper-sweep/references/consumer-contract.md` (v1). Where the two
disagree, that file wins and this one is the bug.

gh-reaper remains the remover. `guard-exec` does not know how to remove a
worktree; it runs the argv gh-reaper hands it.

## Configuration

```
REAPER_FENCE_HELPER=/abs/path/to/ownership_fence.py
REAPER_FENCE_PYTHON=/abs/path/to/python3
```

Both are required, both must be absolute, and there is no `PATH` lookup, no
discovery and no relative resolution on either — the contract is explicit about
this, and a guard found by searching `PATH` is a guard a stale shell gets to
choose. That is also why the interpreter is configured rather than a shim: a
`#!/bin/sh … exec python3` wrapper reintroduces exactly the `PATH` lookup the
contract removed.

The removal command follows the producer's pinned-Git policy rather than the
caller's `PATH`: `/opt/homebrew/bin/git`, then `/usr/local/bin/git`, then
`/usr/bin/git`, first installed executable wins. This matters on hosts whose
interactive environment exposes a package-manager shim before the system Git.
The producer compares the executable path exactly and refuses a different one.

The guard is a **hard dependency of every removal, unconditionally.** There is
no unguarded path left in the tool:

- **Either variable unset** — `fence_helper_unconfigured`, nothing removed.
  Absence of configuration is not evidence that nothing is fenced; it is an
  unanswered question, and an unanswered question protects.
- **Set but unusable** — not absolute, interpreter not executable, script not
  readable — `fence_helper_unusable`, and again nothing is removed.
- **Not actually an interpreter** — `fence_interpreter_unusable`. Absolute,
  regular and executable does not mean "runs Python". `/usr/bin/true` is all
  three: pointed at it, the guard invocation runs nothing and exits 0, and a
  receipt check that trusted exit status would then agree — reporting a reap of
  a worktree that is still there. So before any removal the interpreter is
  asked to hand back a value only this call knows, and anything that cannot is
  refused.

This is about ordinary misconfiguration. Someone who can replace binaries as
this user is outside anything the tool can claim, and it does not pretend
otherwise.

`--force` is not a way around either. It selects which *classifications* are
eligible for removal; it has never been, and is not, a way to skip the guard.

## One call, not three

```
"$REAPER_FENCE_PYTHON" "$REAPER_FENCE_HELPER" guard-exec \
  --repository     <abs canonical main worktree> \
  --candidate-path <abs canonical worktree being removed> \
  --local-ref  <refs/heads/…|"">   --local-oid  <40-hex|absent> \
  --remote-ref <refs/heads/…|"">   --remote-oid <40-hex|absent> \
  --removal-path normal|force|orphan|lock-lift \
  -- <native removal argv…>
```

Inside one held `retirement.lock`, the helper evaluates protection, takes
durable `remove-prepared` custody, runs gh-reaper's argv as a child in its own
process group, postchecks that the candidate is absent, proves the child's
process group is gone, and only then closes custody.

gh-reaper therefore **never**:

- takes or waits on that lock itself;
- splits the call into verdict / prepare / complete around its own deletion —
  the shape that creates both a deadlock and a forgeable "I already hold the
  lock" assertion;
- reads `domain.json`, the `enrolled` witness or the reservations directory;
- implements a marker-exists test of any kind.

**The lock is not the safety mechanism.** Safety is the durable
`remove-prepared` record; serialisation is the lock; terminality is the
process-group check. If the helper dies mid-removal the reservation stays
`remove-prepared`, which every compliant remover reads as protected. (The
producer additionally passes the lock file descriptor to the child and marks it
inheritable, so the flock survives on the shared open file description rather
than falling open the instant the wrapper dies — but that hardens serialisation,
it is not what makes the removal safe.)

### Enrollment is the helper's answer

gh-reaper has no enrolment parser and must not grow one — two parsers drift, and
the drift lands on the destructive side. `managed` in the receipt is logged, not
branched on. A helper that cannot answer protects.

## A zero exit is a claim; the receipt is the proof

Exit 0 alone is never reported as success. gh-reaper re-reads the receipt — the
last non-empty line of the guard's stdout, which is kept separate from its
stderr so diagnostics cannot pollute it — and requires **all** of:

| Field | Required value |
| --- | --- |
| `schemaVersion` | JSON integer `1` |
| `outcome` | `removed` |
| `protected` | JSON boolean `false` |
| `candidatePath` | exactly the candidate we asked to remove |
| `localRef` / `remoteRef` | exactly the refs we sent |
| `removalPath` | exactly the path we declared |
| `postcheck` | `absent` |
| `groupLiveness` | `gone` |
| `custody` | `completed`, or `not_applicable` in an unenrolled domain |
| `removedResources` | exactly one `path`, optionally one `local`; never `remote`, duplicates, or unknown values |

An empty, truncated, malformed or mismatched receipt is a failure, and
`custody: retained` — the guard deliberately keeping custody — is never success.
A receipt naming a different candidate is the one that matters most: without
this check, a guard that removed something else entirely would be reported as a
clean reap of this worktree.

Parsing uses the same pinned interpreter that runs the guard, so there is no
second JSON implementation to drift out of step and no `PATH`-resolved
dependency on the destructive path. The validator's **answer** is what counts,
not its exit status: it prints back a per-call value that only a program which
ran every check to the end can produce, and the shell requires exactly that
value. A parser that never ran exits 0 just as readily as one that passed.

## Exit codes

| Code | Meaning | Removal ran | gh-reaper |
| ---: | --- | --- | --- |
| 0 | cleared, postcheck passed, custody closed | yes | reports reaped **only if the receipt proves it** |
| 3 | refused: protected or mismatched | no | skips, logs the `fence_*` reason |
| 4 | ran but did not verify | yes | failure; custody retained on purpose |
| 5 | child argv exited non-zero | yes | failure; surfaces child status |
| 2 | helper error | no | refuses |
| other | unrecognised | unknown | refuses |

## Identity

The compound identity is (candidate path, local ref, remote ref), and a named
ref must carry the exact version being acted on.

- `--local-ref` is the worktree's checked-out branch; `--local-oid` its HEAD.
- `--remote-ref` is the candidate's ref **on the origin**, so it is
  `refs/heads/<branch>` as the remote knows it, read from
  `branch.<name>.merge` — not the local remote-tracking mirror
  `refs/remotes/origin/<branch>`, which the helper rejects outright.
  Its OID is read from `@{upstream}`, the only version of the remote side
  observable without the network.
- It is reported **only when the branch actually tracks `origin`**, checked
  against `branch.<name>.remote`. A branch tracking a backup or a fork names a
  different repository; substituting its ref would invite the fence to clear a
  version nobody asked about. Anything that is not literally `origin` reports no
  remote ref at all, which protects.
- Empty refs stay empty. Fields are joined with US (`0x1f`), not a tab: tab is
  an IFS whitespace character, so `read` collapses runs of it and every later
  field shifts left the moment a ref is empty — precisely the detached-HEAD and
  no-upstream cases.
- Unresolvable versions are reported as `absent` rather than guessed; the
  helper refuses rather than clearing an unproven version.

Paths are canonicalised with `pwd -P` before they are sent, because the helper
canonicalises and rejects anything that is not already its own realpath.

## Removal paths — coverage is PARTIAL

| Path | Status |
| --- | --- |
| normal | guarded: `git -C <repo> worktree remove <wt>` |
| force | guarded: `git -C <repo> worktree remove --force <wt>` |
| orphan | **unsupported** — refused |
| lock-lift | guarded: `git -C <repo> worktree remove --force --force <wt>` |
| empty-parent prune | **unsupported** — skipped |
| `--prune` | **unsupported** — skipped |

This is a partial integration and should not be read as compatibility. The
normal, force and lock-lift paths can be expressed as an exactly guarded
mutation; the rest have no guarded form at all, so they refuse. Downgrading them
to unguarded mutation on a possibly fenced resource would defeat the fence, and
refusing is the only honest alternative. Each is a live seam question for the
producer, recorded below.

The consequence is real and worth stating plainly: under the guard, orphans are
not reaped at all, `--prune` does nothing, and emptied container directories
accumulate. Those are regressions against the unfenced tool, and they are the
price of never removing anything unadjudicated.

The guarded argv is `<pinned git> -C <repo> worktree remove [--force]
<candidate>`. The helper's argv allowlist consumes git's value-taking global
options before reading the subcommand, so `-C` is supported.

## Open seams with the producer

Recorded here because a consumer that silently works around a contract gap is
worse than one that refuses and says which gap.

1. **Orphan has no expressible mutation.** An orphan is removed with `rm -rf`,
   but the allowlist pins the executable to git, so no orphan removal can be
   guarded. `--removal-path orphan` exists in the contract with nothing that can
   legally be run under it. An orphan's `--repository` is also unresolvable by
   definition: its main repository is what is gone.
2. ~~`lock-lift` cannot pass postcheck.~~ **Resolved.** A separate
   `git worktree unlock` could never satisfy the absence postcheck, but the lift
   and the removal do not have to be two commands: the allowlist permits
   repeated `--force`, so a stale lock is cleared by a single
   `worktree remove --force --force` carrying `--removal-path lock-lift`. One
   guarded mutation, a meaningful postcheck, and no window in which the lock is
   lifted but the removal was then refused.
3. **Empty-parent pruning and `--prune` are unadjudicated.** `rmdir <parent>` is
   not a pinned git command, and `git worktree prune` is repository-wide with no
   candidate path to postcheck, so neither can be expressed as a guarded
   mutation. Both are skipped.
4. **Helper resolution is still the parent's call.** This side implements the
   contract's interim answer: a required configured absolute path, required
   unconditionally, with an unset variable refusing rather than passing through.

## Tests

Two suites, and the distinction between them is load-bearing.

**Acceptance** — `tests/fence-pairing.sh`, run against the real producer:

```bash
FENCE_PRODUCER=/abs/path/to/ownership_fence.py \
FENCE_PYTHON=/abs/path/to/python3 \
  tests/fence-pairing.sh
```

Real enrolment, real reservation records, the real lock, the real `guard-exec`.
It **fails** when the producer is not configured, and there is no default path
baked in: a suite that returns success when its dependency is absent is worse
than no suite, because it reports green for something it never ran. It is not
wired into CI, because the producer lives in a different repository; running it
is coordinated rather than automatic.

It covers the reservation states, crash, races of a removal against `release`,
`reactivate`, re-ownership and `admit-operation` plus a second remover, lease
expiry, ref identity, receipt validation, and a candidate path containing
spaces and shell metacharacters.

Races contend for the **same** resource. The re-ownership race is a producer
taking a fresh reservation on exactly the path the remover is deleting; a
reservation on some other worktree would not contend for anything.

A race is only a race if both sides ran and something happened, so that is
asserted rather than assumed. Crucially, a removal is judged by what the tool
**reported** and what actually **happened**, never by its exit status: gh-reaper
prints per-candidate failures and still exits zero, so treating a zero exit as a
successful removal would let a run in which nothing was removed pass. The two
must also agree -- reporting a reap without the resource going, or the reverse,
fails.

Synchronisation is a fact rather than a delay: both sides announce readiness and
wait on a gate that opens only once both have announced. On top of that, the two
interleavings that matter are pinned deterministically -- removal first, then
re-ownership must fail; re-ownership first, then the removal must be refused --
so correctness does not rest on winning a scheduling coin flip. Positive controls
prove each operation and a plain removal succeed alone.

Nothing in this suite signals a process it did not record itself, and nothing
signals a bare pid. The guard runs under `tests/guard-supervisor.py`, which
keeps the guard as an unreaped `Popen` handle; the suite asks for a kill by
creating a control file, and the supervisor signals its own child and reports
the `wait()` status, so delivery is proved rather than assumed and a recycled
pid cannot be hit. An earlier revision matched `guard-exec` globally with
`pgrep -f` and killed the first hit, which could have been any process on the
host — a tool whose purpose is to never touch what it cannot prove it owns
cannot have a test that does exactly that.

### Crash coverage, and exactly where the post-custody cut is

The crash coverage is:

- a durable `remove-prepared` record, which is what such a crash leaves behind,
  proving the next remover refuses it rather than taking it over;
- a real `SIGKILL` of the guard while it is queued for the lock, which is
  **pre-admission**: it proves a dying guard removes nothing and takes no
  custody, and it is labelled as that; and
- a real `SIGKILL` of the guard **after admission and durable custody**,
  with its admitted child alive and holding the inherited lock ("Crash after
  custody"). On 2026-09-13 the paired suite passed all 56 tests against source
  producer `dca1d75b55e63862dfebb97c0e83bbb0806976c0`, including the positive
  case, negative controls, two behavioral cleanup controls and one structural
  trap-wiring check. That historical run used test source `12edb54`; later
  `4fdcdf2` made the exit trap call the exact `cut_resettle` function exercised
  by the behavioral check. The 12edb54 run is retained history, not final proof.
  An actual INT/TERM delivery test is not claimed by the structural check.

Subsequent local source-pair runs passed 56/56 against renewal producer
`af21a2e98ba860d52b52c3c9b7adf7acead70ec0` and then
`186add8a91129b9510c3efef487df3908a5e63be`, with consumer test source `4fdcdf2`
(the `88f7cd4` consumer commit changed only documentation). The latter producer's
full suite passed 485/485. These dated measurements are synthetic source tests,
not installed, caller or live-cleanup qualification; installation pins are not
advanced. Final independent source acceptance is recorded separately from this
API reference. Baseline discovery/classification tests use an explicit double
and never count as ownership-fence evidence.

The post-custody case runs the actual consumer against the real producer
`guard-exec` with the validated native `git worktree remove` argv. The guard
runs under `tests/guard-supervisor.py` in its test-only `custody-cut` mode,
whose owned child is `tests/custody-cut.py`: it loads the exact producer script
the consumer handed to the interpreter, calls the producer's own `main` with
the original arguments, and replaces only the producer's private
`_spawn_removal` scheduling seam. The already validated argv goes to the real
spawn behind a Python barrier stage parked on a FIFO the test owns; released,
the stage runs that argv as its own child with the lock descriptor passed on,
closes its descriptor, attempts the bounded completion announcement, and
records the exact wait status durably as its last act. Verdict, argv
validation and custody are untouched, and neither the producer nor gh-reaper is
modified or exposed to the mode.

It asserts, in order: `remove-prepared` is durable before the child announces
it is parked; the lock is held; the supervisor kills only its retained wrapper
handle and reports wait status `-9`; the lock is **still** held, which only the
surviving child's inherited open file description can do; a competing
reservation is refused `retirement_busy` and a competing gh-reaper run removes
nothing; releasing the barrier lets the native removal run and report exit 0;
custody is still `remove-prepared` because no wrapper survived to close it; the
killed run reported no reap; and a second gh-reaper run against the recreated
candidate, and a re-ownership attempt, are both refused.

Two negative controls run the identical scenario with one property removed —
the inherited descriptor, then the custody write — and must observe the
opposite, so the positive case cannot pass vacuously:

- without the inherited descriptor, the lock falls open on wrapper death and a
  competing reservation is admitted;
- without the custody write, the producer's own `verdict` on the **same**,
  still-parked candidate is `released` before the kill and, after it,
  unprotected and not `remove-prepared`. This is the observation the producer's
  own wrapper-death control makes. An earlier draft instead expected a second
  consumer to remove a worktree *recreated* at the path afterwards; that was an
  invalid control, because the recreated worktree is a different identity and
  the producer rightly refuses it as `fence_identity_drift` whether or not
  custody exists, so it could never tell dropped custody apart.

The positive case's post-death refusal of a second consumer against the
recreated candidate is kept as asserted: there it must be refused, and it is.

The suite waits through bounded FIFO rendezvous (`tests/custody-handshake.py`),
not timing-based race assumptions, and no pid is searched for or signalled. The one signal outside the
supervisor is the barrier stage's own: its wait on the native removal is
bounded, and on timeout it kills exactly its retained `Popen` handle and still
requires a real wait status; without one it records no completion at all.
Durability failures of the test's own records are not swallowed.

Cleanup finishes only on positive evidence: the consumer run's exit status and,
whenever the wrapper recorded an expected child before spawning, that child's
own durable completion status. There is no "spawn failed, so absent" record —
an exception from inside a spawn does not prove no child exists. If either
piece of evidence is missing within the bound, the suite fails, does not wait
further, and keeps the whole temporary fixture rather than deleting it beneath
a possibly running child. A timeout is never read as proof a child is gone.

**Scope, stated exactly:** the cut is after admission and custody and before the
validated native removal is executed. It is *not* Git stopped part-way through
its own unlink; that interior is not reachable without instrumenting Git, and
nothing here claims it.

### Status of the evidence

The runs above are dated source measurements. `dca1d75` is the producer
baseline, not the final renewal-extension source; its historical measurement
is not promoted to final proof. Final source-pair acceptance requires both
independent producer and consumer review evidence and is recorded separately
by Sandkeep. Neither these source tests nor this API reference qualify an
*installed* copy or a live caller.

Where this consumer stands against the current contract:

1. **argv binding.** The guard requires the argv to carry `-C <repository>` and
   exactly one positional candidate bound to the adjudicated resource. This
   consumer sends exactly that.
2. **`--force` counting** is exact per path: 0 for `normal`, 1 for `force`, 2
   for `lock-lift`. The double-force stale-lock path matches.
3. **No user `-c`.** This consumer never sends `git -c`. The guard injects its
   own hook and fsmonitor neutralisers, which appear in the receipt's `argv`
   field for logging only — that field is deliberately never compared against
   what was sent, because it is not what was sent.
4. **`removedResources`** is required and is checked: a worktree removal must
   prove `path`. Removing a worktree path does not delete its branch, so the
   guard does not claim it did, and `outcome: removed` with
   `custody: completed | not_applicable` keeps its meaning — no loosening of
   this consumer's acceptance was needed or made.

**Baseline** — `tests/test.sh`: discovery, classification and reaping behaviour.
Because nothing can be reaped without a guard, it configures an **explicit test
double** that implements no fence logic at all. It is labelled as one in the
file and in its own output. A pass there is never evidence the fence works.
