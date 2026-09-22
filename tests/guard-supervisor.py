#!/usr/bin/env python3
"""Test-only supervisor that owns the guard process it starts.

Stands in for the configured interpreter (`REAPER_FENCE_PYTHON`). When the
consumer runs the guard, this starts the real interpreter as its own subprocess
and keeps the `Popen` handle, unreaped, for the lifetime of the run.

Why a handle rather than a pid: a pid read from a file is a number, and by the
time anything signals it the process it named may have exited and the number may
have been reused. Signalling through a retained child handle cannot hit anything
but that child, and `wait()` afterwards reports what was actually delivered
rather than what was attempted. Nothing outside this process ever signals
anything; callers ask by creating a control file.

Environment:
    SUPERVISOR_PYTHON  absolute path to the real interpreter
    SUPERVISOR_CTL     directory used for control and result files

Control files, all inside SUPERVISOR_CTL:
    started   written once the guard subprocess exists
    kill      created by the test to ask for SIGKILL of the owned child
    result    written here: the exact wait() status, negative for a signal
"""

import os
import signal
import subprocess
import sys
import time

CTL_STARTED = "started"
CTL_KILL = "kill"
CTL_RESULT = "result"

# SUPERVISOR_MODE (optional, test-only):
#     unset        run `SUPERVISOR_PYTHON ARGS...` exactly as before
#     custody-cut  run tests/custody-cut.py as the owned child in place of the
#                  guard; SUPERVISOR_CUT picks the variant (see that file)
MODE_CUSTODY_CUT = "custody-cut"
CUT_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "custody-cut.py")


def main() -> int:
    real = os.environ["SUPERVISOR_PYTHON"]
    control = os.environ["SUPERVISOR_CTL"]
    arguments = sys.argv[1:]

    # Receipt validation calls the interpreter as `-c`. That is not the guard;
    # it is supervised by nobody and must behave as a plain interpreter.
    if arguments and arguments[0] == "-c":
        os.execv(real, [real] + arguments)

    started = os.path.join(control, CTL_STARTED)
    kill_requested = os.path.join(control, CTL_KILL)
    result = os.path.join(control, CTL_RESULT)

    mode = os.environ.get("SUPERVISOR_MODE", "")
    if mode == "":
        command = [real] + arguments
    elif mode == MODE_CUSTODY_CUT:
        # Test-only: the owned child becomes the custody-cut wrapper, which runs
        # the same producer script with the same arguments and interposes only
        # the producer's private spawn seam. Everything below -- the retained
        # handle, the kill request, the reported wait status -- is unchanged.
        if len(arguments) < 2 or arguments[1] != "guard-exec" or not os.path.isabs(arguments[0]):
            with open(result, "w") as handle:
                handle.write("supervisor-refused:custody-cut needs SCRIPT guard-exec")
            return 2
        command = [real, CUT_SCRIPT, "wrapper"] + arguments
    else:
        with open(result, "w") as handle:
            handle.write("supervisor-refused:unknown SUPERVISOR_MODE " + repr(mode))
        return 2

    child = subprocess.Popen(command)
    with open(started, "w") as handle:
        handle.write(str(child.pid))

    while True:
        if os.path.exists(kill_requested):
            child.kill()
            status = child.wait()
            with open(result, "w") as handle:
                handle.write(str(status))
            # Report whether the signal was actually delivered, not whether it
            # was sent: only a wait status of -SIGKILL proves delivery.
            return 0 if status == -signal.SIGKILL else 1
        status = child.poll()
        if status is not None:
            with open(result, "w") as handle:
                handle.write(str(status))
            return status if status >= 0 else 1
        time.sleep(0.01)


if __name__ == "__main__":
    sys.exit(main())
