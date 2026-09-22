#!/usr/bin/env python3
"""Test-only FIFO handshakes for the post-custody wrapper-death acceptance case.

Used by tests/fence-pairing.sh, never by gh-reaper. It owns no process and
signals nothing: every rendezvous is a named FIFO the test created, and every
wait is bounded. It is invoked through the pinned FENCE_PYTHON.

Subcommands:

    await FIFO PREFIX TIMEOUT [ABORT]
        Read one newline-terminated line from FIFO and print it. Exit 0 if it
        starts with PREFIX, 2 if it does not, 3 if the file ABORT appears before
        any line arrives, 4 on timeout. This process keeps its own write end
        open while it waits, so a FIFO nobody has written to yet is never
        mistaken for an announcement that closed without content.

    release FIFO TIMEOUT [ABORT]
        Write "go" to FIFO once something is reading it. Exit 0 when written,
        3 if ABORT appears first, 4 if nothing ever read it.

    unpark CTL FINISHED TIMEOUT [--hold]
        Bounded cleanup: hold CTL/ready.fifo and CTL/done.fifo open and drained
        and offer CTL/barrier.fifo until the file FINISHED exists AND, if
        CTL/child_expected exists, CTL/child.status exists and the stage's
        CTL/stage.alive flock is free (the stage has exited). Exit 0 on that
        positive evidence; on timeout print what is unproven and exit 4 -- a
        timeout is never taken as proof a child is gone. `--hold` never offers
        the barrier (failure-path control only).

    lock-state LOCK
        Print "held" or "free" for a non-blocking exclusive flock of LOCK, or
        "missing" if LOCK does not exist.
"""

import errno
import fcntl
import os
import select
import sys
import time

POLL = 0.05


def appeared(path: str) -> bool:
    return bool(path) and os.path.exists(path)


def await_line(fifo: str, prefix: str, timeout: float, abort: str) -> int:
    deadline = time.monotonic() + timeout
    reader = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
    keeper = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    buffer = b""
    try:
        while True:
            if b"\n" in buffer:
                line = buffer.split(b"\n", 1)[0].decode("utf-8", "replace")
                print(line, flush=True)
                return 0 if line.startswith(prefix) else 2
            if appeared(abort):
                print("aborted:" + buffer.decode("utf-8", "replace"), flush=True)
                return 3
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                print("timeout:" + buffer.decode("utf-8", "replace"), flush=True)
                return 4
            if select.select([reader], [], [], min(POLL, remaining))[0]:
                try:
                    buffer += os.read(reader, 256)
                except BlockingIOError:
                    continue
    finally:
        os.close(keeper)
        os.close(reader)


def offer(fifo: str) -> bool:
    try:
        descriptor = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as error:
        if error.errno in (errno.ENXIO, errno.ENOENT):
            return False
        raise
    try:
        os.write(descriptor, b"go\n")
    except OSError as error:
        if error.errno not in (errno.EPIPE, errno.EAGAIN):
            raise
        return False
    finally:
        os.close(descriptor)
    return True


def release(fifo: str, timeout: float, abort: str) -> int:
    deadline = time.monotonic() + timeout
    while True:
        if offer(fifo):
            return 0
        if appeared(abort):
            return 3
        if time.monotonic() >= deadline:
            return 4
        time.sleep(POLL)


def hold_open(fifo: str):
    """A reader that stays open for the whole cleanup, plus our own write end.

    Opening and closing a reader per poll could leave a child that opened the
    FIFO in between writing into a pipe with no reader, killing it with EPIPE
    before it ever reported. Holding both ends for the duration avoids that.
    """
    try:
        reader = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        keeper = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        os.close(reader)
        return None
    return reader, keeper


def drain(reader: int) -> None:
    while select.select([reader], [], [], 0)[0]:
        try:
            if not os.read(reader, 256):
                return
        except BlockingIOError:
            return


def flock_state(path: str) -> str:
    """"held", "free" or "missing" for a non-blocking exclusive flock probe."""
    try:
        descriptor = os.open(path, os.O_RDWR)
    except FileNotFoundError:
        return "missing"
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return "held"
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        return "free"
    finally:
        os.close(descriptor)


def accounted(control: str, finished: str) -> str:
    """Empty when everything is proved finished; otherwise what is not."""
    missing = []
    if appeared(os.path.join(control, "child_expected")):
        # Only the stage's own final status counts, and only once the flock it
        # holds for its whole life is free -- which the kernel does at its exit.
        # There is no "absent" record: an expected child that never reported is
        # unproven, never presumed gone.
        if not appeared(os.path.join(control, "child.status")):
            missing.append("an admitted child was expected and has not recorded completion")
        elif flock_state(os.path.join(control, "stage.alive")) != "free":
            missing.append("the stage recorded completion but has not exited")
    if not appeared(finished):
        missing.append("the consumer run has not reported its exit status")
    return "; ".join(missing)


def unpark(control: str, finished: str, timeout: float, hold: bool = False) -> int:
    """Finish only on positive evidence: consumer status AND child completion.

    A timeout proves nothing about the child, so it is reported as unproven
    and the caller must keep the fixture. With `hold` the barrier is never
    offered: that models a cleanup that cannot unpark, for the failure-path
    control, and it can only ever end unproven while a child is parked.
    """
    deadline = time.monotonic() + timeout
    held = [pair for pair in (hold_open(os.path.join(control, "ready.fifo")),
                              hold_open(os.path.join(control, "done.fifo")))
            if pair is not None]
    try:
        while True:
            for reader, _ in held:
                drain(reader)
            missing = accounted(control, finished)
            if not missing:
                return 0
            if time.monotonic() >= deadline:
                print("unproven: " + missing, flush=True)
                return 4
            if not hold:
                offer(os.path.join(control, "barrier.fifo"))
            time.sleep(POLL)
    finally:
        for reader, keeper in held:
            os.close(keeper)
            os.close(reader)


USAGE = "usage: custody-handshake.py await|release|unpark|lock-state ..."


def main(argv: list) -> int:
    command, rest = (argv[0], argv[1:]) if argv else ("", [])
    if command == "await" and len(rest) in (3, 4):
        return await_line(rest[0], rest[1], float(rest[2]), rest[3] if len(rest) == 4 else "")
    if command == "release" and len(rest) in (2, 3):
        return release(rest[0], float(rest[1]), rest[2] if len(rest) == 3 else "")
    if command == "unpark" and len(rest) == 3:
        return unpark(rest[0], rest[1], float(rest[2]))
    if command == "unpark" and len(rest) == 4 and rest[3] == "--hold":
        return unpark(rest[0], rest[1], float(rest[2]), hold=True)
    if command == "lock-state" and len(rest) == 1:
        print(flock_state(rest[0]))
        return 0
    print(USAGE, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
