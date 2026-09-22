#!/usr/bin/env python3
"""Test-only custody cut for tests/fence-pairing.sh. Never used by gh-reaper.

Two roles, both started with the real pinned interpreter:

wrapper SCRIPT guard-exec ARGS...
    Started by tests/guard-supervisor.py in `custody-cut` mode in place of
    `python SCRIPT guard-exec ARGS...`. It loads the exact producer module at
    SCRIPT (the path the consumer itself handed to the interpreter), replaces
    ONLY the producer's private `_spawn_removal` scheduling seam, and calls the
    producer's own `main` with the original arguments. Verdict, argv validation
    and the custody write are the producer's; the argv the seam receives is
    therefore already validated, and it is passed on unchanged.

    SUPERVISOR_CUT selects the variant, inside this dedicated test process only:
      inherit     positive: the real `_spawn_removal` starts the barrier stage
                  with the real inherited lock descriptor
      no-inherit  negative control: the same real `_spawn_removal`, every
                  argument intact except that the descriptor handed on is a
                  /dev/null one of the same kind instead of the lock's
      no-custody  negative control: real spawn, but the producer's
                  `prepare_removal_locked` is made a no-op

    Before any spawn it durably records CTL/child_expected. Nothing ever records
    a child as absent: a spawn that raises proves nothing either way, so an
    expected child without a completion record makes cleanup retain the
    fixture.

stage CTL FD|none -- ARGV...
    The admitted child, a Python process (not a shell). First it takes an
    exclusive flock on CTL/stage.alive that only its exit releases. Every FIFO
    step is bounded by RENDEZVOUS_SECONDS: announce "ready\\n" on
    CTL/ready.fifo, read one line from CTL/barrier.fifo, then run the validated
    ARGV as its own child (the descriptor passed on) and wait for it, bounded
    by NATIVE_WAIT_SECONDS; on timeout it kills exactly that retained `Popen`
    handle and requires a wait status within KILL_WAIT_SECONDS. It then closes
    its own copy of the descriptor, attempts the bounded announcement of the
    outcome on CTL/done.fifo, and as its LAST act atomically writes
    CTL/child.status: line 1 the outcome, line 2 "announce=ok|failed".

    Outcomes: done:<rc> | timeout-killed:<rc> | spawn-error:<errno> |
    ready-timeout | barrier-timeout. The only case that writes no status is a
    native child with no proved wait status; it exits 3 and the fixture is
    retained. `cut_error` is an optional diagnostic; child_expected and
    child.status are the required records, and their write failures propagate.

verdict SCRIPT COMMON CANDIDATE LOCAL_REF REMOTE_REF LOCAL_OID REMOTE_OID
    Read-only observation, made identically in the positive case (which must
    see remove-prepared and protected after wrapper death) and the no-custody
    control (which must see the opposite): loads the exact producer script and
    prints `state=<state> protected=<true|false>` from its own `verdict`, the
    observation the producer's wrapper-death test makes.

The only signal sent anywhere here is the stage's bounded-timeout kill of its
own retained child handle. Nothing looks a process up by pid or name.
"""

import errno
import fcntl
import importlib.util
import inspect
import os
import select
import subprocess
import sys
import time

VARIANTS = ("inherit", "no-inherit", "no-custody")
HERE = os.path.abspath(__file__)
# The native removal of a tiny synthetic worktree; far above what it needs, and
# below the suite's 300 s wait for the child's completion announcement.
NATIVE_WAIT_SECONDS = 120
KILL_WAIT_SECONDS = 60
# Every FIFO rendezvous the stage makes is bounded by this.
RENDEZVOUS_SECONDS = 300
POLL = 0.05


def atomic_write(path: str, text: str) -> None:
    temporary = path + ".tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(descriptor, text.encode("utf-8"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, path)
    # Durability is claimed, so a failure to make it durable is not swallowed:
    # it propagates, and the caller never reports the record as written.
    directory = os.open(os.path.dirname(path) or ".", os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def refuse(control: str, reason: str) -> int:
    """Refuse to interpose. `cut_error` is an optional diagnostic, not a record
    anything relies on; if it cannot be written, that is said on stderr."""
    print("custody-cut: " + reason, file=sys.stderr, flush=True)
    if control:
        try:
            atomic_write(os.path.join(control, "cut_error"), reason + "\n")
        except OSError as error:
            print("custody-cut: could not record cut_error: %s" % error,
                  file=sys.stderr, flush=True)
    return 2


def parameters_of(function) -> dict:
    try:
        return dict(inspect.signature(function).parameters)
    except (TypeError, ValueError):
        return {}


def load_producer(script: str):
    directory = os.path.dirname(script)
    if directory not in sys.path:
        sys.path.insert(0, directory)
    spec = importlib.util.spec_from_file_location("ownership_fence", script)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load producer from " + script)
    module = importlib.util.module_from_spec(spec)
    sys.modules["ownership_fence"] = module
    spec.loader.exec_module(module)
    return module


def descriptor_number(descriptor):
    if isinstance(descriptor, int):
        return descriptor
    fileno = getattr(descriptor, "fileno", None)
    return fileno() if callable(fileno) else None


# Substitute descriptors stay referenced for the wrapper's life, so a file
# object is never closed by garbage collection under the native spawn.
KEEP = []


def substitute_descriptor(descriptor):
    """A /dev/null descriptor of the same kind as the lock descriptor given."""
    if isinstance(descriptor, int):
        return os.open(os.devnull, os.O_RDONLY)
    if callable(getattr(descriptor, "fileno", None)):
        return open(os.devnull, "rb")
    raise TypeError("no-inherit cannot substitute a descriptor of type %s"
                    % type(descriptor).__name__)


def wrapper(arguments: list) -> int:
    control = os.environ.get("SUPERVISOR_CTL", "")
    variant = os.environ.get("SUPERVISOR_CUT", "")
    if not control or not os.path.isabs(control) or not os.path.isdir(control):
        return refuse("", "SUPERVISOR_CTL must be an existing absolute directory")
    if variant not in VARIANTS:
        return refuse(control, "unknown SUPERVISOR_CUT: " + repr(variant))
    if len(arguments) < 2 or arguments[1] != "guard-exec":
        return refuse(control, "custody-cut only interposes guard-exec")
    script = arguments[0]
    if not os.path.isabs(script) or not os.path.isfile(script):
        return refuse(control, "producer script must be an absolute file: " + script)

    producer = load_producer(script)
    native = getattr(producer, "_spawn_removal", None)
    entry = getattr(producer, "main", None)
    if not callable(native):
        return refuse(control, "producer has no _spawn_removal seam")
    if not callable(entry):
        return refuse(control, "producer has no main entry point")
    if variant == "no-custody" and not callable(getattr(producer, "prepare_removal_locked", None)):
        return refuse(control, "producer has no prepare_removal_locked to drop")

    expected = os.path.join(control, "child_expected")

    def interposed(argv, descriptor, environment, *rest, **named):
        """Scheduling interposition only: `argv` is already validated.

        `child_expected` is made durable before the spawn is attempted. If the
        spawn raises, nothing is recorded as absent: an exception from inside a
        spawn does not prove no child exists, so the child stays expected and
        cleanup, lacking its completion record, retains the fixture.
        """
        if variant == "no-inherit":
            # The same native spawn, with every other argument intact; only the
            # descriptor it hands on is a /dev/null one of the same kind rather
            # than the lock's. Whether the producer's spawn accepts `None` is not
            # something this test can establish, so it is not relied on. The
            # substitute is made before `child_expected`, so if it cannot be
            # made, provably nothing was spawned.
            descriptor = substitute_descriptor(descriptor)
            KEEP.append(descriptor)
        number = descriptor_number(descriptor)
        passed = "none" if number is None else str(number)
        stage = [sys.executable, HERE, "stage", control, passed, "--", *argv]
        atomic_write(expected, variant + "\n")
        return native(stage, descriptor, environment, *rest, **named)

    producer._spawn_removal = interposed
    if variant == "no-custody":
        producer.prepare_removal_locked = lambda *rest, **named: None

    sys.argv = [script, *arguments[1:]]
    try:
        code = entry(arguments[1:]) if parameters_of(entry) else entry()
    except SystemExit as leaving:
        code = leaving.code
    if code is None:
        return 0
    if isinstance(code, int):
        return code
    print(code, file=sys.stderr)
    return 1


def hold_life_lock(control: str) -> int:
    """Take the flock this stage holds until it exits.

    The descriptor is never closed by this code and is non-inheritable, so no
    descendant keeps it: the kernel releases the lock exactly when this process
    exits. A cleanup that finds child.status AND this lock free therefore knows
    the stage itself is gone, without looking at any pid.
    """
    descriptor = os.open(os.path.join(control, "stage.alive"),
                         os.O_RDWR | os.O_CREAT, 0o600)
    # Blocking: a cleanup probe holds it only for an instant, and must not be
    # able to make the stage die before it records anything.
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    return descriptor


def write_line_bounded(path: str, line: str, deadline: float) -> bool:
    """Write one short line to a FIFO once a reader exists; False on deadline.

    Opening non-blocking means no reader is `ENXIO`, not an indefinite block.
    A reader vanishing between open and write is reported as False, never
    swallowed as success.
    """
    while True:
        try:
            descriptor = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as error:
            if error.errno != errno.ENXIO:
                raise
            if time.monotonic() >= deadline:
                return False
            time.sleep(POLL)
            continue
        try:
            os.write(descriptor, (line + "\n").encode("utf-8"))
            return True
        except BrokenPipeError:
            return False
        finally:
            os.close(descriptor)


def read_line_bounded(path: str, deadline: float):
    """One line from a FIFO, or None at the deadline. Never blocks unbounded."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    buffer = b""
    try:
        while True:
            if b"\n" in buffer:
                return buffer.split(b"\n", 1)[0].decode("utf-8", "replace")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            if not select.select([descriptor], [], [], min(POLL, remaining))[0]:
                continue
            try:
                chunk = os.read(descriptor, 256)
            except BlockingIOError:
                continue
            if not chunk:
                # No writer at the moment (none yet, or one that left): bounded wait.
                time.sleep(min(POLL, max(remaining, 0)))
                continue
            buffer += chunk
    finally:
        os.close(descriptor)


def stage(arguments: list) -> int:
    if len(arguments) < 4 or arguments[2] != "--":
        print("custody-cut stage: CTL FD|none -- ARGV...", file=sys.stderr)
        return 64
    control, passed, argv = arguments[0], arguments[1], arguments[3:]
    hold_life_lock(control)
    descriptor = None
    if passed != "none":
        try:
            descriptor = int(passed)
            os.fstat(descriptor)
        except (ValueError, OSError):
            descriptor = None

    outcome = None
    if not write_line_bounded(os.path.join(control, "ready.fifo"), "ready",
                              time.monotonic() + RENDEZVOUS_SECONDS):
        outcome = "ready-timeout"
    elif read_line_bounded(os.path.join(control, "barrier.fifo"),
                           time.monotonic() + RENDEZVOUS_SECONDS) is None:
        outcome = "barrier-timeout"
    else:
        try:
            child = subprocess.Popen(
                argv, pass_fds=(descriptor,) if descriptor is not None else ())
        except OSError as error:
            # Popen raising OSError has already reaped a child whose exec
            # failed, or never forked one: no native child exists.
            outcome = "spawn-error:%d" % (error.errno or 0)
        else:
            try:
                outcome = "done:%d" % child.wait(timeout=NATIVE_WAIT_SECONDS)
            except subprocess.TimeoutExpired:
                # Bounded: signal only this exact retained handle, then require
                # an actual wait status as proof it is gone.
                child.kill()
                try:
                    outcome = "timeout-killed:%d" % child.wait(timeout=KILL_WAIT_SECONDS)
                except subprocess.TimeoutExpired:
                    outcome = None

    if descriptor is not None:
        # Not swallowed: if our copy of the lock cannot be closed, completion is
        # not reported, and the fixture is retained.
        os.close(descriptor)

    if outcome is None:
        # No wait status: the native child is not proved gone. Record nothing
        # that cleanup would accept as completion.
        print("custody-cut stage: native child not proved finished", file=sys.stderr, flush=True)
        return 3

    # Announce first, bounded; the status is the LAST thing this process does,
    # so nothing that could block follows it and a cleanup that accepts it can
    # never strand this stage. Whether the announcement reached anyone is part
    # of the record rather than silently dropped.
    announced = write_line_bounded(os.path.join(control, "done.fifo"), outcome,
                                   time.monotonic() + RENDEZVOUS_SECONDS)
    atomic_write(os.path.join(control, "child.status"),
                 "%s\nannounce=%s\n" % (outcome, "ok" if announced else "failed"))
    return 0 if outcome == "done:0" else 1


def verdict(arguments: list) -> int:
    """Read-only: the producer's own verdict on one candidate identity."""
    if len(arguments) != 7:
        print("custody-cut verdict: SCRIPT COMMON CANDIDATE LOCAL_REF REMOTE_REF "
              "LOCAL_OID REMOTE_OID", file=sys.stderr)
        return 64
    script, common, candidate, local_ref, remote_ref, local_oid, remote_oid = arguments
    if not os.path.isabs(script) or not os.path.isfile(script):
        print("custody-cut verdict: producer script must be an absolute file", file=sys.stderr)
        return 2
    producer = load_producer(script)
    judge = getattr(producer, "verdict", None)
    if not callable(judge):
        print("custody-cut verdict: producer has no verdict", file=sys.stderr)
        return 2
    names = parameters_of(judge)
    named = {}
    for name, value in (("remote_ref", remote_ref), ("local_oid", local_oid),
                        ("remote_oid", remote_oid)):
        if name in names:
            named[name] = value
    try:
        answer = judge(common, candidate, local_ref, **named)
    except Exception as error:  # report, never guess an answer
        print("error:%s:%s" % (type(error).__name__, getattr(error, "reason", error)),
              flush=True)
        return 2
    print("state=%s protected=%s" % (
        answer.get("state"), "true" if answer.get("protected") else "false"), flush=True)
    return 0


def main() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] == "wrapper":
        return wrapper(sys.argv[2:])
    if len(sys.argv) >= 2 and sys.argv[1] == "stage":
        return stage(sys.argv[2:])
    if len(sys.argv) >= 2 and sys.argv[1] == "verdict":
        return verdict(sys.argv[2:])
    print("usage: custody-cut.py wrapper|stage|verdict ...", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main())
