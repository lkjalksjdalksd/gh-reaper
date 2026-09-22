#!/usr/bin/env bash
#
# ACCEPTANCE: gh-reaper against the real ownership-fence producer.
#
# This suite is paired-source acceptance evidence. It runs the actual producer
# ownership_fence.py -- real enrolment, real reservation records, the real
# shared lock, the real guard-exec. A double implementing an imagined protocol
# proves nothing about a destructive integration.
#
# It therefore FAILS, rather than skipping, when the producer is not configured.
# A suite that silently returns success when its dependency is absent is worse
# than no suite: it reports green for a thing it never ran.
#
# Required, both absolute, no defaults and no discovery:
#   FENCE_PRODUCER=/abs/path/to/ownership_fence.py
#   FENCE_PYTHON=/abs/path/to/python3
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAPER="$ROOT/gh-reaper"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

fatal() { printf "${RED}ACCEPTANCE CANNOT RUN${NC}\n  -> %s\n" "$1" >&2; exit 1; }

[ -n "${FENCE_PRODUCER:-}" ] || fatal "FENCE_PRODUCER is not set (absolute path to ownership_fence.py)"
[ -n "${FENCE_PYTHON:-}" ]   || fatal "FENCE_PYTHON is not set (absolute path to a python3)"
case "$FENCE_PRODUCER" in /*) ;; *) fatal "FENCE_PRODUCER must be absolute: $FENCE_PRODUCER" ;; esac
case "$FENCE_PYTHON"   in /*) ;; *) fatal "FENCE_PYTHON must be absolute: $FENCE_PYTHON" ;; esac
[ -r "$FENCE_PRODUCER" ] || fatal "FENCE_PRODUCER is not readable: $FENCE_PRODUCER"
[ -x "$FENCE_PYTHON" ]   || fatal "FENCE_PYTHON is not executable: $FENCE_PYTHON"
command -v git >/dev/null 2>&1 || fatal "git is required"

HELPER="$FENCE_PRODUCER"
SUPERVISOR="$SCRIPT_DIR/guard-supervisor.py"
[ -x "$SUPERVISOR" ] || fatal "tests/guard-supervisor.py is not executable"
TMPROOT="$(mk_realpath_tmpdir)"
# A fixture under which an admitted child was not PROVED finished is kept, not
# deleted: removing it could pull the rendezvous and repository out from under
# a process that is still running. The failure that set this is already
# reported; this only says where the evidence was left.
#
# Every cut whose completion is not yet proved is registered here while it is
# live (CUT_JOB/CUT_CTL) or after a cleanup that could not prove it
# (CUT_PENDING). The exit trap -- also reached on INT and TERM -- gives each of
# them one more bounded, proof-requiring cleanup, and deletes TMPROOT only if
# every one of them is then proved finished. Anything else retains it.
CUT_RETAINED=""
CUT_PENDING=""
CUT_JOB=""
CUT_CTL=""
finish_tmproot() {
    local ctl
    if [ -n "${CUT_JOB:-}" ]; then
        CUT_PENDING="${CUT_PENDING:-} $CUT_CTL"
        CUT_JOB=""
    fi
    for ctl in ${CUT_PENDING:-}; do
        if ! cut_resettle "$ctl" 60; then
            CUT_RETAINED="$CUT_RETAINED $(dirname "$ctl")"
        fi
    done
    if [ -n "$CUT_RETAINED" ]; then
        printf 'RETAINED %s: child completion unproven under:%s\n' "$TMPROOT" "$CUT_RETAINED" >&2
    else
        rm -rf "$TMPROOT"
    fi
}
trap finish_tmproot EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The producer is invoked exactly as the consumer invokes it: pinned absolute
# interpreter, pinned absolute script. No shim, no PATH.
fence() { "$FENCE_PYTHON" "$HELPER" "$@"; }

jf() { "$FENCE_PYTHON" -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"; }

mksbx() { mk_sandbox "$TMPROOT/$1"; }

# Enrol and drive a real reserve -> bind -> [release] -> [prepare] lifecycle.
stage() {
    local b="$1" want="$2" lease="${3:-}" oid tok dig rev gen
    fence enroll --repository "$b/repo" --role worktree >/dev/null || return 1
    oid="$(g -C "$b/wt-clean" rev-parse HEAD)"
    # shellcheck disable=SC2086
    fence reserve --repository "$b/repo" --reservation-id res-1 --role worktree \
        --candidate-path "$b/wt-clean" \
        --local-ref refs/heads/feat-clean --remote-ref refs/heads/feat-clean \
        --expected-local-oid "$oid" --expected-remote-oid "$oid" \
        $lease > "$b/reserve.json" || return 1
    tok="$(jf "$b/reserve.json" ownerToken)"
    dig="$(jf "$b/reserve.json" recordDigest)"
    rev="$(jf "$b/reserve.json" revision)"
    gen="$(jf "$b/reserve.json" generation)"
    fence bind --repository "$b/repo" --reservation-id res-1 \
        --expected-digest "$dig" --expected-revision "$rev" --expected-generation "$gen" \
        --owner-token "$tok" > "$b/bind.json" || return 1
    [ "$want" = "active" ] && return 0

    dig="$(jf "$b/bind.json" recordDigest)"
    rev="$(jf "$b/bind.json" revision)"
    gen="$(jf "$b/bind.json" generation)"
    fence release --repository "$b/repo" --reservation-id res-1 \
        --expected-digest "$dig" --expected-revision "$rev" --expected-generation "$gen" \
        --owner-token "$tok" > "$b/release.json" || return 1
    [ "$want" = "released" ] && return 0

    # remove-prepared is the state a remover that died mid-removal leaves behind.
    dig="$(jf "$b/release.json" recordDigest)"
    rev="$(jf "$b/release.json" revision)"
    gen="$(jf "$b/release.json" generation)"
    fence prepare-removal --repository "$b/repo" --reservation-id res-1 \
        --expected-digest "$dig" --expected-revision "$rev" --expected-generation "$gen" \
        > "$b/prepare.json" || return 1
    return 0
}

record_state() {
    "$FENCE_PYTHON" -c "import json,sys;print(json.load(open(sys.argv[1]))['state'])" \
        "$1/repo/.git/reaper/fence/reservations/res-1.json" 2>/dev/null || printf 'missing'
}

reap() {
    REAPER_FENCE_HELPER="$HELPER" REAPER_FENCE_PYTHON="$FENCE_PYTHON" \
        "$REAPER" --reap --yes --force --no-color --path "$1" 2>&1
}

present() { [ -e "$1/wt-clean" ] && echo y || echo n; }

# ---------------------------------------------------------------------------
# Configuration is required, unconditionally
# ---------------------------------------------------------------------------
check
B="$(mksbx unset_plain)"
out="$( unset REAPER_FENCE_HELPER REAPER_FENCE_PYTHON
        "$REAPER" --reap --yes --no-color --path "$B" 2>&1 )"
if [ -e "$B/wt-clean" ] && [[ "$out" == *"fence_helper_unconfigured"* ]]; then
    ok "unset configuration refuses removal"
else
    no "unset configuration refuses removal" "present=$(present "$B") out=$out"
fi

check
B="$(mksbx unset_forced)"
echo scratch >> "$B/wt-clean/c.txt"
out="$( unset REAPER_FENCE_HELPER REAPER_FENCE_PYTHON
        "$REAPER" --reap --yes --force --no-color --path "$B" 2>&1 )"
if [ -e "$B/wt-clean" ] && [[ "$out" == *"fence_helper_unconfigured"* ]]; then
    ok "unset configuration refuses even with --force"
else
    no "unset configuration refuses even with --force" "present=$(present "$B") out=$out"
fi

check
B="$(mksbx half)"
out="$( unset REAPER_FENCE_PYTHON
        REAPER_FENCE_HELPER="$HELPER" "$REAPER" --reap --yes --no-color --path "$B" 2>&1 )"
if [ -e "$B/wt-clean" ] && [[ "$out" == *"fence_helper_unconfigured"* ]]; then
    ok "helper without interpreter refuses"
else
    no "helper without interpreter refuses" "present=$(present "$B") out=$out"
fi

check
B="$(mksbx relative)"
out="$( REAPER_FENCE_HELPER="$HELPER" REAPER_FENCE_PYTHON="python3" \
        "$REAPER" --reap --yes --no-color --path "$B" 2>&1 )"
if [ -e "$B/wt-clean" ] && [[ "$out" == *"fence_helper_unusable"* ]]; then
    ok "PATH-resolved interpreter is refused, not looked up"
else
    no "PATH-resolved interpreter is refused, not looked up" "present=$(present "$B") out=$out"
fi

check
B="$(mksbx missing)"
out="$( REAPER_FENCE_HELPER="$TMPROOT/nope.py" REAPER_FENCE_PYTHON="$FENCE_PYTHON" \
        "$REAPER" --reap --yes --no-color --path "$B" 2>&1 )"
if [ -e "$B/wt-clean" ] && [[ "$out" == *"fence_helper_unusable"* ]]; then
    ok "missing helper script refuses"
else
    no "missing helper script refuses" "present=$(present "$B") out=$out"
fi

# ---------------------------------------------------------------------------
# The interpreter must actually be an interpreter
# ---------------------------------------------------------------------------
# "Absolute, regular, executable" is not the same as "runs Python". A program
# like /usr/bin/true satisfies all three, accepts every invocation and exits 0,
# so a consumer that trusts exit status would run no guard, remove nothing, and
# still report a reap. These assert the worktree survives AND that nothing was
# reported as reaped -- the reporting half is the actual regression.
not_an_interpreter_case() {
    local name="$1" interpreter="$2" b out
    check
    b="$(mksbx "$3")"
    out="$( REAPER_FENCE_HELPER="$HELPER" REAPER_FENCE_PYTHON="$interpreter" \
            "$REAPER" --reap --yes --force --no-color --path "$b" 2>&1 )"
    if [ -e "$b/wt-clean" ] && ! printf '%s' "$out" | grep -q ' reaped ' \
       && printf '%s' "$out" | grep -q 'fence_interpreter_unusable'; then
        ok "$name"
    else
        no "$name" "present=$(present "$b") out=$out"
    fi
}

if [ -x /usr/bin/true ]; then
    not_an_interpreter_case \
        "a no-op executable as interpreter removes nothing and reports nothing" \
        /usr/bin/true interp_true
fi
if [ -x /bin/echo ]; then
    not_an_interpreter_case \
        "an executable that echoes its arguments is refused as interpreter" \
        /bin/echo interp_echo
fi

check
B="$(mksbx interp_silent)"
SILENT="$TMPROOT/silent-interpreter"
{
    printf '#!/bin/sh\n'
    printf 'if [ "$1" = "-c" ] && [ -n "${REAPER_FENCE_PROBE:-}" ]; then\n'
    printf '  printf %%s "$REAPER_FENCE_PROBE"; exit 0\n'
    printf 'fi\n'
    printf 'exit 0\n'
} > "$SILENT"
chmod +x "$SILENT"
out="$( REAPER_FENCE_HELPER="$HELPER" REAPER_FENCE_PYTHON="$SILENT" \
        "$REAPER" --reap --yes --force --no-color --path "$B" 2>&1 )"
if [ -e "$B/wt-clean" ] && ! printf '%s' "$out" | grep -q ' reaped ' \
   && printf '%s' "$out" | grep -q 'receipt did not prove'; then
    ok "an interpreter that validates nothing cannot report a removal"
else
    no "an interpreter that validates nothing cannot report a removal" \
       "present=$(present "$B") out=$out"
fi

# PATH may expose a package-manager Git that differs from the producer's pinned
# executable. The consumer must use the same fixed selection policy rather than
# handing the guard whichever executable this shell resolves first.
PINNED_GIT=""
for candidate in /opt/homebrew/bin/git /usr/local/bin/git /usr/bin/git; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
        PINNED_GIT="$candidate"
        break
    fi
done
[ -n "$PINNED_GIT" ] || fatal "no producer-compatible system Git executable"
PATH_SHADOW="$TMPROOT/path-shadow"
mkdir -p "$PATH_SHADOW"
{
    printf '#!/bin/sh\n'
    printf 'exec "%s" "$@"\n' "$PINNED_GIT"
} > "$PATH_SHADOW/git"
chmod +x "$PATH_SHADOW/git"

check
B="$(mksbx path_git_mismatch)"
out="$(PATH="$PATH_SHADOW:$PATH" reap "$B")"
if [ ! -e "$B/wt-clean" ] && [[ "$out" == *" reaped "* ]]; then
    ok "the guard receives its pinned Git even when PATH resolves another executable"
else
    no "the guard receives its pinned Git even when PATH resolves another executable" "$out"
fi

# ---------------------------------------------------------------------------
# Reservation states
# ---------------------------------------------------------------------------
check
B="$(mksbx unenrolled)"
out="$(reap "$B")"
[ ! -e "$B/wt-clean" ] && ok "unenrolled domain removes through the guard, not around it" \
                       || no "unenrolled domain removes through the guard, not around it" "$out"

check
B="$(mksbx active)"
if stage "$B" active; then
    out="$(reap "$B")"
    if [ -e "$B/wt-clean" ] && [ "$(record_state "$B")" = "active" ]; then
        ok "active reservation protects and is not consumed"
    else
        no "active reservation protects and is not consumed" "present=$(present "$B") state=$(record_state "$B") out=$out"
    fi
else
    no "active reservation protects and is not consumed" "staging failed"
fi

check
B="$(mksbx released)"
if stage "$B" released; then
    out="$(reap "$B")"
    if [ ! -e "$B/wt-clean" ] && [ "$(record_state "$B")" = "removed" ]; then
        ok "released reservation is removed and tombstoned"
    else
        no "released reservation is removed and tombstoned" "present=$(present "$B") state=$(record_state "$B") out=$out"
    fi
else
    no "released reservation is removed and tombstoned" "staging failed"
fi

check
B="$(mksbx norecord)"
fence enroll --repository "$B/repo" --role worktree >/dev/null 2>&1
out="$(reap "$B")"
[ -e "$B/wt-clean" ] && ok "enrolled domain with no record protects" \
                     || no "enrolled domain with no record protects" "$out"

check
B="$(mksbx corrupt)"
if stage "$B" released; then
    rec="$B/repo/.git/reaper/fence/reservations/res-1.json"
    chmod 600 "$rec"; printf '{ not json' > "$rec"
    out="$(reap "$B")"
    [ -e "$B/wt-clean" ] && ok "corrupt reservation record protects" \
                         || no "corrupt reservation record protects" "$out"
else
    no "corrupt reservation record protects" "staging failed"
fi


# Wait for a file to appear. No `seq`: it is not in POSIX and is absent on some
# systems this script is expected to run on.
wait_for_file() {
    local path="$1" limit="${2:-400}" i=0
    while [ "$i" -lt "$limit" ]; do
        [ -e "$path" ] && return 0
        i=$((i + 1))
        sleep 0.02
    done
    return 1
}

# Hold the repository retirement lock from outside. Everything that then wants
# the lock queues behind it, which is how these tests get a deterministic
# barrier: both parties are started, both block, and releasing the lock lets
# them contend at a known moment rather than whenever they happen to arrive.
#
# Started directly rather than through a command substitution: a background
# process inside `$(...)` keeps the substitution pipe open, so the caller waits
# for it and the pid it gets back is not the one it wanted.
LOCK_HOLDER=""
hold_lock() {
    local common="$1/repo/.git" ready="$2" release="$3"
    mkdir -p "$common/reaper"
    chmod 700 "$common/reaper"
    "$FENCE_PYTHON" -c '
import fcntl, os, sys, time
lock, ready, release = sys.argv[1], sys.argv[2], sys.argv[3]
fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(ready, "w").close()
deadline = time.time() + 60
while not os.path.exists(release) and time.time() < deadline:
    time.sleep(0.02)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
' "$common/reaper/retirement.lock" "$ready" "$release" >/dev/null 2>&1 &
    LOCK_HOLDER=$!
}

# ---------------------------------------------------------------------------
# Crash: a guard that dies leaves no removal behind
# ---------------------------------------------------------------------------
check  # A remover that died after taking custody leaves a durable
# remove-prepared record, and the next remover must refuse it rather than take
# it over. This is the post-custody half of crash safety, and it is exact.
B="$(mksbx crashed)"
if stage "$B" remove-prepared; then
    out="$(reap "$B")"
    if [ -e "$B/wt-clean" ] && [ "$(record_state "$B")" = "remove-prepared" ]; then
        ok "custody left by a crashed remover protects and is not stolen"
    else
        no "custody left by a crashed remover protects and is not stolen" "present=$(present "$B") state=$(record_state "$B") out=$out"
    fi
else
    no "custody left by a crashed remover protects and is not stolen" "staging failed"
fi

check  # Killing the guard itself. The signal goes through a supervisor that
# owns the guard as a retained subprocess handle, so nothing here signals a
# number that could name a different process by the time it lands, and delivery
# is proved by the wait status the supervisor reports (-9), not by kill's
# return. The barrier is the held lock, so the guard is killed while it is
# queued for it -- BEFORE admission. This is not the post-custody,
# lock-inherited case; that one is "Crash after custody" below.
B="$(mksbx killed)"
if stage "$B" released; then
    ctl="$B/ctl"; mkdir -p "$ctl"
    ready="$B/l.ready"; release="$B/l.release"
    hold_lock "$B" "$ready" "$release"
    holder=$LOCK_HOLDER

    if ! wait_for_file "$ready"; then
        no "a guard killed before admission removes nothing and takes no custody" \
           "lock barrier never acquired"
        touch "$release"; wait "$holder" 2>/dev/null
    else
        ( SUPERVISOR_PYTHON="$FENCE_PYTHON" SUPERVISOR_CTL="$ctl" \
          REAPER_FENCE_HELPER="$HELPER" REAPER_FENCE_PYTHON="$SUPERVISOR" \
          REAPER_RETIREMENT_LOCK_WAIT=30 \
          "$REAPER" --reap --yes --force --no-color --path "$B" >"$B/reap.out" 2>&1 ) &
        reaper_job=$!

        if wait_for_file "$ctl/started"; then
            touch "$ctl/kill"
            wait_for_file "$ctl/result" || true
        fi
        touch "$release"
        wait "$holder" 2>/dev/null
        wait "$reaper_job" 2>/dev/null

        delivered="$(cat "$ctl/result" 2>/dev/null || printf 'none')"
        st="$(record_state "$B")"
        if [ "$delivered" = "-9" ] && [ -e "$B/wt-clean" ] && [ "$st" = "released" ]; then
            ok "a guard killed before admission removes nothing and takes no custody"
        else
            no "a guard killed before admission removes nothing and takes no custody" \
               "wait_status=$delivered present=$(present "$B") state=$st"
        fi
    fi
else
    no "a guard killed before admission removes nothing and takes no custody" "staging failed"
fi

# The post-admission case -- a guard killed *after* it has taken remove-prepared
# custody, with its admitted child holding the inherited lock -- is asserted in
# "Crash after custody" below, once the race helpers it reuses are defined.

# ---------------------------------------------------------------------------
# Races: producer operations overlapping a removal
# ---------------------------------------------------------------------------
# Every race uses the same barrier and the same invariant:
#
#   if the worktree is gone, the record must be a `removed` tombstone;
#   if the record is in any protecting state, the worktree must still be there;
#
# and both sides must have actually run and be accounted for. A race where one
# side failed to start is not a race, so its exit status is asserted rather than
# discarded. Positive controls below prove each operation succeeds on its own,
# so a green race cannot come from an operation that never works at all.
# Whether the tool actually reported a removal, as opposed to exiting zero.
# gh-reaper prints per-candidate failures and still ends successfully, so its
# exit status says nothing about whether this candidate was removed.
removal_reported() { grep -q ' reaped ' "$1" 2>/dev/null; }

# Run a command only once the gate opens, announcing first that it is ready.
# The barrier is a fact -- both sides have signalled -- rather than a guess
# about how long starting a process takes.
armed_run() {
    local armed="$1" gate="$2"; shift 2
    : > "$armed"
    wait_for_file "$gate" || return 127
    "$@"
}

# A producer operation contending with a removal for the same resource.
#
# Correctness is asserted as an invariant that must hold for every interleaving,
# because the point of the fence is that no interleaving is unsafe:
#
#   what the tool reported must match what actually happened;
#   if the resource is gone, the record must be a `removed` tombstone;
#   if the record still protects, the resource must still be there;
#
# plus the run must not be vacuous: both sides must have run, and at least one
# must have achieved something. The deterministic both-orders cases below pin
# the two interleavings that matter exactly.
race() {
    local name="$1" b="$2" opfn="$3"
    local ready="$b/l.ready" release="$b/l.release" gate="$b/gate"
    local armed_rm="$b/armed.rm" armed_op="$b/armed.op" holder rj oj

    hold_lock "$b" "$ready" "$release"
    holder=$LOCK_HOLDER
    if ! wait_for_file "$ready"; then
        no "$name" "lock barrier never acquired"
        touch "$release"; wait "$holder" 2>/dev/null
        return
    fi

    (
        armed_run "$armed_rm" "$gate" true || exit 127
        REAPER_RETIREMENT_LOCK_WAIT=30 reap "$b" > "$b/reap.out" 2>&1
        printf '%s' "$?" > "$b/reap.rc"
    ) &
    rj=$!
    (
        armed_run "$armed_op" "$gate" true || exit 127
        REAPER_RETIREMENT_LOCK_WAIT=30 "$opfn" "$b" > "$b/op.out" 2>&1
        printf '%s' "$?" > "$b/op.rc"
    ) &
    oj=$!

    if wait_for_file "$armed_rm" && wait_for_file "$armed_op"; then
        : > "$gate"
    fi
    touch "$release"
    wait "$holder" 2>/dev/null
    wait "$rj" 2>/dev/null
    wait "$oj" 2>/dev/null

    local orc st gone reported
    orc="$(cat "$b/op.rc" 2>/dev/null || printf 'none')"
    st="$(record_state "$b")"
    if [ -e "$b/wt-clean" ]; then gone=no; else gone=yes; fi
    if removal_reported "$b/reap.out"; then reported=yes; else reported=no; fi

    if [ ! -e "$b/reap.rc" ] || [ "$orc" = none ]; then
        no "$name" "a side never ran: operation=$orc"
    elif [ "$reported" != "$gone" ]; then
        no "$name" "reported reaped=$reported but resource gone=$gone"
    elif [ "$gone" = yes ] && [ "$st" != "removed" ]; then
        no "$name" "resource gone but record is $st (operation=$orc)"
    elif [ "$gone" = no ] && [ "$st" = "removed" ]; then
        no "$name" "record tombstoned but resource is still present (operation=$orc)"
    elif [ "$gone" = no ] && [ "$orc" != 0 ]; then
        no "$name" "nothing happened at all: no removal and operation=$orc"
    else
        ok "$name"
    fi
}

op_release() {
    local b="$1"
    fence release --repository "$b/repo" --reservation-id res-1 \
        --expected-digest "$(jf "$b/bind.json" recordDigest)" \
        --expected-revision "$(jf "$b/bind.json" revision)" \
        --expected-generation "$(jf "$b/bind.json" generation)" \
        --owner-token "$(jf "$b/reserve.json" ownerToken)"
}

op_reactivate() {
    local b="$1"
    fence reactivate --repository "$b/repo" --reservation-id res-1 \
        --expected-digest "$(jf "$b/release.json" recordDigest)" \
        --expected-revision "$(jf "$b/release.json" revision)" \
        --expected-generation "$(jf "$b/release.json" generation)" \
        --owner-token "$(jf "$b/reserve.json" ownerToken)"
}

# `create` here is re-ownership of the EXACT resource the remover is targeting:
# once res-1 is released the worktree is removable, and a producer taking a new
# reservation on that same path is racing the removal for it. Creating some
# other worktree alongside would not contend for anything.
op_create() {
    local b="$1" oid
    oid="$(g -C "$b/wt-clean" rev-parse HEAD)"
    fence reserve --repository "$b/repo" --reservation-id res-2 --role worktree \
        --candidate-path "$b/wt-clean" --local-ref refs/heads/feat-clean \
        --expected-local-oid "$oid" > "$b/reserve2.json" || return 1
    fence bind --repository "$b/repo" --reservation-id res-2 \
        --expected-digest "$(jf "$b/reserve2.json" recordDigest)" \
        --expected-revision "$(jf "$b/reserve2.json" revision)" \
        --expected-generation "$(jf "$b/reserve2.json" generation)" \
        --owner-token "$(jf "$b/reserve2.json" ownerToken)"
}

# Admission names the process group that will do the work, so the operation can
# later be proved finished rather than merely claimed finished.
op_admit() {
    local b="$1" pgid
    pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
    [ -n "$pgid" ] || return 1
    fence admit-operation --repository "$b/repo" --reservation-id res-1 \
        --expected-digest "$(jf "$b/bind.json" recordDigest)" \
        --expected-revision "$(jf "$b/bind.json" revision)" \
        --expected-generation "$(jf "$b/bind.json" generation)" \
        --owner-token "$(jf "$b/reserve.json" ownerToken)" \
        --operation-id op-1 --operation capture \
        --owner-pid $$ --owner-pgid "$pgid"
}

# ---- positive controls: each operation works on its own -------------------
control() {
    local name="$1" want="$2" opfn="$3" b rc=0
    check
    b="$(mksbx "ctl_$name")"
    if ! stage "$b" "$want"; then
        no "control: $name succeeds on its own" "staging failed"
        return
    fi
    "$opfn" "$b" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && ok "control: $name succeeds on its own" \
                    || no "control: $name succeeds on its own" "exit $rc"
}

control release    active   op_release
control reactivate released op_reactivate
control create     released op_create
control admit      active   op_admit

check  # control: a removal on its own succeeds, so a race that removes nothing
# cannot be mistaken for correct behaviour.
B="$(mksbx ctl_removal)"
if stage "$B" released; then
    reap "$B" >/dev/null 2>&1
    [ ! -e "$B/wt-clean" ] && ok "control: a guarded removal succeeds on its own" \
        || no "control: a guarded removal succeeds on its own" "worktree survived"
else
    no "control: a guarded removal succeeds on its own" "staging failed"
fi

# ---- the races themselves --------------------------------------------------
check; B="$(mksbx race_release)"
if stage "$B" active; then race "release racing a removal" "$B" op_release
else no "release racing a removal" "staging failed"; fi

check; B="$(mksbx race_reactivate)"
if stage "$B" released; then race "reactivate racing a removal" "$B" op_reactivate
else no "reactivate racing a removal" "staging failed"; fi

check; B="$(mksbx race_create)"
if stage "$B" released; then race "re-owning the same resource racing its removal" "$B" op_create
else no "re-owning the same resource racing its removal" "staging failed"; fi

# ---- the two interleavings that matter, pinned exactly --------------------
check
B="$(mksbx order_reap_first)"
if stage "$B" released; then
    reap "$B" > "$B/reap.out" 2>&1
    if ! removal_reported "$B/reap.out" || [ -e "$B/wt-clean" ] \
       || [ "$(record_state "$B")" != "removed" ]; then
        no "removal first, then re-ownership: the removal is real and reported" \
           "present=$(present "$B") state=$(record_state "$B")"
    else
        ord_rc=0; op_create "$B" > "$B/op.out" 2>&1 || ord_rc=$?
        if [ "$ord_rc" -ne 0 ]; then
            ok "removal first, then re-ownership: the removal is real and reported"
        else
            no "removal first, then re-ownership: the removal is real and reported" \
               "re-owned a resource that was already removed"
        fi
    fi
else
    no "removal first, then re-ownership: the removal is real and reported" "staging failed"
fi

check
B="$(mksbx order_op_first)"
if stage "$B" released; then
    ord_rc=0; op_create "$B" > "$B/op.out" 2>&1 || ord_rc=$?
    if [ "$ord_rc" -ne 0 ]; then
        no "re-ownership first, then removal: the removal is refused" \
           "re-ownership failed on its own"
    else
        reap "$B" > "$B/reap.out" 2>&1
        if [ -e "$B/wt-clean" ] && ! removal_reported "$B/reap.out"; then
            ok "re-ownership first, then removal: the removal is refused"
        else
            no "re-ownership first, then removal: the removal is refused" \
               "present=$(present "$B")"
        fi
    fi
else
    no "re-ownership first, then removal: the removal is refused" "staging failed"
fi

check; B="$(mksbx race_admit)"
if stage "$B" active; then race "admit racing a removal" "$B" op_admit
else no "admit racing a removal" "staging failed"; fi

check  # two removers, same candidate, same lock
B="$(mksbx raced)"
if stage "$B" released; then
    o1="$B/race1.txt"; o2="$B/race2.txt"
    ( reap "$B" > "$o1" 2>&1 ) & p1=$!
    ( reap "$B" > "$o2" 2>&1 ) & p2=$!
    wait "$p1" 2>/dev/null; wait "$p2" 2>/dev/null
    wins=0
    grep -q ' reaped ' "$o1" && wins=$((wins+1))
    grep -q ' reaped ' "$o2" && wins=$((wins+1))
    if [ "$wins" -eq 1 ] && [ ! -e "$B/wt-clean" ] && [ "$(record_state "$B")" = "removed" ]; then
        ok "concurrent removers: exactly one wins, the record is tombstoned once"
    else
        no "concurrent removers: exactly one wins, the record is tombstoned once" \
           "wins=$wins present=$(present "$B") state=$(record_state "$B")"
    fi
else
    no "concurrent removers: exactly one wins, the record is tombstoned once" "staging failed"
fi

check  # EXPIRY: a lease that ran out is an observation about a process, never
# removal authority.
B="$(mksbx expired)"
if stage "$B" active "--lease-hours 0.0003"; then
    sleep 2
    out="$(reap "$B")"
    st="$(record_state "$B")"
    if [ -e "$B/wt-clean" ] && [ "$st" = "active" ]; then
        ok "an expired lease does not demote a reservation or authorise removal"
    else
        no "an expired lease does not demote a reservation or authorise removal" \
           "present=$(present "$B") state=$st out=$out"
    fi
else
    no "an expired lease does not demote a reservation or authorise removal" "staging failed"
fi

# ---------------------------------------------------------------------------
# Crash after custody: the wrapper dies, the admitted child does not
# ---------------------------------------------------------------------------
# The actual consumer runs the real producer guard-exec with the validated
# native `git worktree remove` argv. The guard runs under guard-supervisor.py in
# its test-only `custody-cut` mode, which imports the exact producer module at
# FENCE_PRODUCER and substitutes nothing but the producer's private
# `_spawn_removal` scheduling seam: the validated argv is handed, unchanged, to
# the real spawn behind a parked Python barrier stage (tests/custody-cut.py).
# Verdict, argv validation and custody are the producer's own. Nothing in gh-reaper or the producer is modified.
#
# SCOPE, stated exactly: the cut is after admission and durable custody and
# before the validated native removal is executed -- not Git stopped inside its
# own unlink. The parked stage is what the real spawn started, so it holds the
# inherited lock descriptor; released, it runs the validated argv, drops the
# descriptor, and announces the exact exit status.
#
# Contract with the supervisor mode (all FIFOs created by this test, in CTL):
#   SUPERVISOR_MODE=custody-cut  SUPERVISOR_CUT=inherit|no-inherit|no-custody
#   stage.alive   the stage holds an exclusive flock on it for its whole life;
#                 the kernel drops it only when the stage exits, so a free
#                 lock plus child.status is proof the stage itself is gone
#   ready.fifo    the stage writes "ready\n" once spawned (bounded open)
#   barrier.fifo  the stage reads one line from it (bounded), then runs the argv
#   done.fifo     the stage writes "<outcome>\n" (bounded) once the native
#                 child's wait status is in hand and its own copy of the lock
#                 descriptor is closed
#   child_expected  written durably by the wrapper BEFORE any spawn
#   child.status    written atomically by the stage as its LAST act, after the
#                   done announcement was attempted, so no blocking operation
#                   follows it: line 1 the outcome, line 2 "announce=ok|failed"
# Outcomes: done:<rc> | timeout-killed:<rc> | spawn-error:<errno> |
#   ready-timeout | barrier-timeout. A native child that is
# not proved reaped leaves NO status. There is no "absent" record: an expected
# child with no status, or whose stage still holds stage.alive, is unproven,
# and cleanup then retains the fixture.
# The mode lives in tests/custody-cut.py (wrapper and child stage).
# `no-inherit` calls the same native spawn with a /dev/null descriptor in place
# of the lock's, so the one property removed is which open file description
# the stage inherits; `no-custody` makes the producer's custody write a no-op. Both are test-only substitutions
# inside the supervisor's own process; neither is reachable from gh-reaper.
#
# The kill goes through the existing supervisor control file and lands only on
# the supervisor's retained wrapper handle; delivery is the wait status it
# reports. No pid is searched for or signalled by this suite, and every wait is
# a bounded FIFO rendezvous or file-status poll, never a timing-based race assumption.
HANDSHAKE="$SCRIPT_DIR/custody-handshake.py"
[ -r "$HANDSHAKE" ] || fatal "tests/custody-handshake.py is not readable"
hs() { "$FENCE_PYTHON" "$HANDSHAKE" "$@"; }
lock_state() { hs lock-state "$1/repo/.git/reaper/retirement.lock"; }

CUT_CTL=""; CUT_JOB=""; CUT_FAIL=""; CUT_STATUS=""; CUT_UNPROVEN=""

CUT_TOOL="$SCRIPT_DIR/custody-cut.py"
[ -r "$CUT_TOOL" ] || fatal "tests/custody-cut.py is not readable"

# The producer's own verdict on the ORIGINAL candidate identity, observed the
# same way in the positive case and in the no-custody control.
cut_verdict() {
    local b="$1" oid="$2"
    "$FENCE_PYTHON" "$CUT_TOOL" verdict "$HELPER" "$b/repo/.git" "$b/wt-clean" \
        refs/heads/feat-clean refs/heads/feat-clean "$oid" "$oid" 2>&1
}

# One bounded, proof-requiring settlement of a cut's control directory. It is
# the only thing that may declare a cut finished, and it is what both the
# per-case cleanup and the exit trap use. `hold` never releases the barrier:
# it models a cleanup that cannot unpark, and must then report unproven.
cut_settle() {
    local ctl="$1" timeout="$2" hold="${3:-}"
    if [ "$hold" = hold ]; then
        hs unpark "$ctl" "$ctl/reap.rc" "$timeout" --hold
    else
        hs unpark "$ctl" "$ctl/reap.rc" "$timeout"
    fi
}

cut_fail() { [ -n "$CUT_FAIL" ] || CUT_FAIL="$1"; return 1; }

# Start the consumer under the supervisor and return once the child is parked.
cut_start() {
    local b="$1" variant="$2" got rc
    CUT_CTL="$b/ctl"; CUT_JOB=""; CUT_STATUS=""
    mkdir -p "$CUT_CTL" || { cut_fail "cannot create control directory"; return 1; }
    mkfifo "$CUT_CTL/ready.fifo" "$CUT_CTL/barrier.fifo" "$CUT_CTL/done.fifo" \
        || { cut_fail "cannot create handshake FIFOs"; return 1; }
    (
        SUPERVISOR_PYTHON="$FENCE_PYTHON" SUPERVISOR_CTL="$CUT_CTL" \
        SUPERVISOR_MODE=custody-cut SUPERVISOR_CUT="$variant" \
        REAPER_FENCE_HELPER="$HELPER" REAPER_FENCE_PYTHON="$SUPERVISOR" \
            "$REAPER" --reap --yes --force --no-color --path "$b" >"$b/reap.out" 2>&1
        printf '%s' "$?" > "$CUT_CTL/reap.rc"
    ) &
    CUT_JOB=$!
    got="$(hs await "$CUT_CTL/ready.fifo" ready 120 "$CUT_CTL/result")"; rc=$?
    case "$rc" in
        0) return 0 ;;
        3) cut_fail "the supervised guard exited with status $(cat "$CUT_CTL/result" 2>/dev/null) and no child ever parked: custody-cut mode was not reached (cut_error=$(cat "$CUT_CTL/cut_error" 2>/dev/null) present=$(present "$b") state=$(record_state "$b"))"; return 1 ;;
        *) cut_fail "the child never announced it was parked (handshake rc=$rc: $got)"; return 1 ;;
    esac
}

# Ask the supervisor to SIGKILL its owned wrapper; read the exact wait status.
cut_kill() {
    : > "$CUT_CTL/kill"
    wait_for_file "$CUT_CTL/result" 3000 || { cut_fail "the supervisor never reported a wait status"; return 1; }
    local i=0
    CUT_STATUS="$(cat "$CUT_CTL/result" 2>/dev/null)"
    while [ -z "$CUT_STATUS" ] && [ "$i" -lt 500 ]; do
        i=$((i + 1)); sleep 0.01
        CUT_STATUS="$(cat "$CUT_CTL/result" 2>/dev/null)"
    done
    [ "$CUT_STATUS" = "-9" ] || { cut_fail "wrapper wait status was '$CUT_STATUS', not -SIGKILL"; return 1; }
}

# Let the parked child run the validated argv; account for its exact status.
cut_run_child() {
    local got rc
    hs release "$CUT_CTL/barrier.fifo" 60 >/dev/null; rc=$?
    [ "$rc" -eq 0 ] || { cut_fail "nothing was parked on the owned barrier (rc=$rc)"; return 1; }
    got="$(hs await "$CUT_CTL/done.fifo" done: 300)"; rc=$?
    [ "$rc" -eq 0 ] || { cut_fail "the released child never reported completion (rc=$rc: $got)"; return 1; }
    [ "$got" = "done:0" ] || { cut_fail "the native removal exited '$got', not done:0"; return 1; }
    # The status is the stage's last act, written after the announcement, so
    # it is awaited as a record of its own -- bounded, never assumed.
    wait_for_file "$CUT_CTL/child.status" 1500 \
        || { cut_fail "the child announced '$got' but never recorded its status"; return 1; }
    local recorded; recorded="$(sed -n 1p "$CUT_CTL/child.status" 2>/dev/null)"
    [ "$recorded" = "$got" ] \
        || { cut_fail "the durable child status '$recorded' does not match its announcement '$got'"; return 1; }
}

# Bounded, and finished only on positive evidence: the consumer run's exit
# status, plus -- whenever an admitted child was expected -- that child's own
# final status AND the release of the flock the stage holds for its whole life.
# Unproven: nothing is waited on, the cut moves to CUT_PENDING, and the exit
# trap will settle it again or retain the fixture. Arguments are for the
# failure-path controls only: a timeout, and `hold`.
cut_cleanup() {
    local timeout="${1:-180}" hold="${2:-}"
    [ -n "$CUT_JOB" ] || return 0
    if CUT_UNPROVEN="$(cut_settle "$CUT_CTL" "$timeout" "$hold" 2>&1)"; then
        wait "$CUT_JOB" 2>/dev/null
        CUT_JOB=""
        CUT_UNPROVEN=""
        return 0
    fi
    CUT_PENDING="$CUT_PENDING $CUT_CTL"
    CUT_JOB=""
    CUT_UNPROVEN="${CUT_UNPROVEN:-no reason given}"
    return 1
}

# A cut still pending is settled here, bounded, by the same proof. Proved: it
# leaves CUT_PENDING. Not proved: it stays, and the exit trap retains it.
cut_resettle() {
    local ctl="$1" timeout="$2" rest="" entry
    cut_settle "$ctl" "$timeout" >/dev/null 2>&1 || return 1
    for entry in $CUT_PENDING; do
        [ "$entry" = "$ctl" ] || rest="$rest $entry"
    done
    CUT_PENDING="$rest"
}

cut_add_other() {
    g -C "$1/repo" worktree add -q "$1/wt-other" -b feat-other >/dev/null 2>&1 \
        || { cut_fail "could not add the competing fixture worktree"; return 1; }
}

cut_reserve_other() {
    local b="$1" oid
    oid="$(g -C "$b/wt-other" rev-parse HEAD)"
    fence reserve --repository "$b/repo" --reservation-id res-probe --role worktree \
        --candidate-path "$b/wt-other" --local-ref refs/heads/feat-other \
        --expected-local-oid "$oid" 2>&1
}

cut_case() {
    local name="$1" sandbox="$2" live="$3" post="$4" b rc
    check
    CUT_FAIL=""; CUT_JOB=""
    b="$(mksbx "$sandbox")"
    if ! stage "$b" released; then
        no "$name" "staging failed"
        return
    fi
    "$live" "$b"; rc=$?
    [ "$rc" -eq 0 ] || cut_fail "live phase failed without a reason"
    if ! cut_cleanup; then
        CUT_FAIL="${CUT_FAIL:+$CUT_FAIL; }cleanup could not prove completion ($CUT_UNPROVEN); kept pending, fixture retained unless later proved"
    fi
    if [ -z "$CUT_FAIL" ] && [ -n "$post" ]; then
        "$post" "$b" || cut_fail "post phase failed without a reason"
    fi
    if [ -z "$CUT_FAIL" ]; then ok "$name"; else no "$name" "$CUT_FAIL"; fi
}

# ---- positive: custody and the inherited lock survive the wrapper ----------
cut_inherit_live() {
    local b="$1" st got rc
    cut_start "$b" inherit || return 1

    [ -e "$CUT_CTL/child_expected" ] || { cut_fail "a child announced ready but the wrapper recorded no expected child"; return 1; }
    st="$(record_state "$b")"
    [ "$st" = "remove-prepared" ] || { cut_fail "child parked but record is $st: custody was not durable before ready"; return 1; }
    [ -e "$b/wt-clean" ] || { cut_fail "candidate gone before the barrier was released"; return 1; }
    [ "$(lock_state "$b")" = "held" ] || { cut_fail "lock not held while the admitted child is parked"; return 1; }
    local oid verdict_now
    oid="$(g -C "$b/wt-clean" rev-parse HEAD)"
    verdict_now="$(cut_verdict "$b" "$oid")"
    [ "$verdict_now" = "state=remove-prepared protected=true" ] \
        || { cut_fail "verdict before the kill was '$verdict_now', not remove-prepared and protected"; return 1; }

    cut_kill || return 1

    [ "$(lock_state "$b")" = "held" ] || { cut_fail "lock fell open on wrapper death: the child did not inherit the flock description"; return 1; }
    [ -e "$b/wt-clean" ] || { cut_fail "candidate gone while the child is still parked"; return 1; }
    # The observation the no-custody control must see the opposite of: the
    # producer's own verdict on this same, still-present, still-parked identity.
    verdict_now="$(cut_verdict "$b" "$oid")"
    [ "$verdict_now" = "state=remove-prepared protected=true" ] \
        || { cut_fail "verdict after wrapper death was '$verdict_now', not remove-prepared and protected"; return 1; }

    cut_add_other "$b" || return 1
    got="$(cut_reserve_other "$b")"; rc=$?
    if [ "$rc" -eq 0 ] || [[ "$got" != *"retirement_busy"* ]]; then
        cut_fail "a competing reservation was not refused retirement_busy: rc=$rc out=$got"; return 1
    fi
    reap "$b/wt-clean" > "$b/compete.out" 2>&1
    if removal_reported "$b/compete.out" || [ ! -e "$b/wt-clean" ]; then
        cut_fail "a competing remover acted while the survivor held the lock: present=$(present "$b") out=$(cat "$b/compete.out")"; return 1
    fi
    st="$(record_state "$b")"
    [ "$st" = "remove-prepared" ] || { cut_fail "competing remover changed custody to $st"; return 1; }
    [ "$(lock_state "$b")" = "held" ] || { cut_fail "lock no longer held after the competitors"; return 1; }

    cut_run_child || return 1

    [ ! -e "$b/wt-clean" ] || { cut_fail "the released native removal did not remove the candidate"; return 1; }
    st="$(record_state "$b")"
    [ "$st" = "remove-prepared" ] || { cut_fail "custody became $st although no wrapper survived to close it"; return 1; }
    [ "$(lock_state "$b")" = "free" ] || { cut_fail "the lock outlived the child that held it"; return 1; }
}

cut_inherit_post() {
    local b="$1" st got rc oid
    if removal_reported "$b/reap.out"; then
        cut_fail "the killed consumer run reported a reap: $(cat "$b/reap.out")"; return 1
    fi
    # The same identity again: path, branch and version exactly as adjudicated.
    g -C "$b/repo" worktree add -q "$b/wt-clean" feat-clean >/dev/null 2>&1 \
        || { cut_fail "could not recreate the candidate fixture"; return 1; }
    reap "$b" > "$b/second.out" 2>&1
    st="$(record_state "$b")"
    if removal_reported "$b/second.out" || [ ! -e "$b/wt-clean" ] || [ "$st" != "remove-prepared" ]; then
        cut_fail "a second consumer was not refused by surviving custody: present=$(present "$b") state=$st out=$(cat "$b/second.out")"; return 1
    fi
    oid="$(g -C "$b/wt-clean" rev-parse HEAD)"
    got="$(fence reserve --repository "$b/repo" --reservation-id res-2 --role worktree \
        --candidate-path "$b/wt-clean" --local-ref refs/heads/feat-clean \
        --expected-local-oid "$oid" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] || [[ "$got" != *"fence_removal_in_progress"* ]]; then
        cut_fail "re-ownership of the custodied candidate was not refused: rc=$rc out=$got"; return 1
    fi
}

cut_case "a guard killed after custody leaves the admitted child holding the lock and custody remove-prepared" \
    cut_inherit cut_inherit_live cut_inherit_post

# ---- negative control: drop the inherited descriptor -----------------------
cut_no_inherit_live() {
    local b="$1" st got rc
    cut_start "$b" no-inherit || return 1
    st="$(record_state "$b")"
    [ "$st" = "remove-prepared" ] || { cut_fail "no-inherit: record is $st, the control changed more than the descriptor"; return 1; }
    [ "$(lock_state "$b")" = "held" ] || { cut_fail "no-inherit: the wrapper did not hold the lock"; return 1; }
    cut_kill || return 1
    [ "$(lock_state "$b")" = "free" ] || { cut_fail "no-inherit: lock still held after wrapper death, so the positive case cannot detect a dropped descriptor"; return 1; }
    cut_add_other "$b" || return 1
    got="$(cut_reserve_other "$b")"; rc=$?
    [ "$rc" -eq 0 ] || { cut_fail "no-inherit: a competing reservation was not admitted: rc=$rc out=$got"; return 1; }
    [ -e "$b/wt-clean" ] || { cut_fail "no-inherit: candidate gone while the child is parked"; return 1; }
    cut_run_child || return 1
}

cut_case "control: without the inherited descriptor the lock falls open and a competitor is admitted" \
    cut_no_inherit cut_no_inherit_live ""

# ---- negative control: drop custody ----------------------------------------
# Observed exactly as the producer's own wrapper-death control observes it: the
# producer's verdict on the SAME candidate, still present and still parked --
# not a recreated worktree, whose new identity is rightly refused as drift and
# so could never show whether custody was what protected it.
#
# Why this control does not mirror the positive case's re-reservation: while
# the child is parked the lock refuses any reservation as retirement_busy with
# or without custody, and once the native removal has run the original
# identity no longer exists, so any later refusal or admission would be about
# a different resource. The verdict on the same parked identity, before and
# after wrapper death, is the one observation in which custody is the only
# difference, and the positive case asserts its opposite.
cut_no_custody_live() {
    local b="$1" st oid before after
    cut_start "$b" no-custody || return 1
    [ -e "$CUT_CTL/child_expected" ] || { cut_fail "no-custody: a child announced ready but none was recorded as expected"; return 1; }
    st="$(record_state "$b")"
    [ "$st" = "released" ] || { cut_fail "no-custody: record is $st, custody was not dropped"; return 1; }
    oid="$(g -C "$b/wt-clean" rev-parse HEAD)"
    before="$(cut_verdict "$b" "$oid")"
    [[ "$before" == "state=released "* ]] || { cut_fail "no-custody: verdict before the kill was '$before', not state released"; return 1; }
    [ "$(lock_state "$b")" = "held" ] || { cut_fail "no-custody: the lock is not held while parked"; return 1; }

    cut_kill || return 1

    [ -e "$b/wt-clean" ] || { cut_fail "no-custody: candidate gone while the child is still parked"; return 1; }
    after="$(cut_verdict "$b" "$oid")"
    case "$after" in
        state=remove-prepared\ *|*protected=true*|error:*|"")
            cut_fail "no-custody: the parked child's candidate is still protected after wrapper death ('$after'), so the positive case cannot detect dropped custody"; return 1 ;;
        *protected=false) ;;
        *) cut_fail "no-custody: unrecognised verdict '$after'"; return 1 ;;
    esac

    cut_run_child || return 1
    [ ! -e "$b/wt-clean" ] || { cut_fail "no-custody: the released native removal did not run"; return 1; }
    st="$(record_state "$b")"
    [ "$st" = "released" ] || { cut_fail "no-custody: record became $st"; return 1; }
}

cut_case "control: without the custody record the surviving child's candidate is unprotected after wrapper death" \
    cut_no_custody cut_no_custody_live ""

# ---- failure paths: cleanup is proof-driven, never presumptive -------------
# These drive the exact failure shapes the reviews found, deterministically:
# no timing is relied on to make them happen, only the owned barrier and the
# supervisor's retained wrapper handle.

# A failed assertion after the kill skips cut_run_child. Cleanup alone must
# then release the barrier and PROVE the stage finished: its final status and
# the release of the life lock only its exit can drop.
cut_cleanup_only_live() {
    local b="$1" first
    cut_start "$b" inherit || return 1
    cut_kill || return 1
    if ! cut_cleanup; then
        cut_fail "cleanup alone could not prove the parked child finished ($CUT_UNPROVEN)"; return 1
    fi
    first="$(sed -n 1p "$CUT_CTL/child.status" 2>/dev/null)"
    [[ "$first" == done:* ]] || { cut_fail "cleanup returned but the child status is '$first'"; return 1; }
    [ "$(hs lock-state "$CUT_CTL/stage.alive")" = "free" ] \
        || { cut_fail "cleanup returned while the stage still held its life lock"; return 1; }
    [ "$(lock_state "$b")" = "free" ] \
        || { cut_fail "the retirement lock is still held after completion was proved"; return 1; }
}

cut_case "failure path: cleanup without the release step still proves the parked child finished" \
    cut_cleanup_only cut_cleanup_only_live ""

# A cleanup that cannot unpark (interrupted, or out of time) must say so, keep
# the cut pending and delete nothing; the settlement the exit trap performs
# must then prove completion before anything is released for deletion.
cut_unproven_live() {
    local b="$1" ctl
    cut_start "$b" inherit || return 1
    cut_kill || return 1
    ctl="$CUT_CTL"
    if cut_cleanup 0 hold; then
        cut_fail "a cleanup that could not unpark the child claimed completion"; return 1
    fi
    [ -n "$CUT_UNPROVEN" ] || { cut_fail "an unproven cleanup gave no reason"; return 1; }
    [[ " $CUT_PENDING " == *" $ctl "* ]] \
        || { cut_fail "the unproven cut was not kept pending for the exit trap"; return 1; }
    [ ! -e "$ctl/child.status" ] || { cut_fail "a child still parked has a completion status"; return 1; }
    [ "$(hs lock-state "$ctl/stage.alive")" = "held" ] \
        || { cut_fail "the parked stage does not hold its life lock"; return 1; }
    [ -e "$b/wt-clean" ] && [ "$(lock_state "$b")" = "held" ] \
        || { cut_fail "an unproven cleanup let something change: present=$(present "$b") lock=$(lock_state "$b")"; return 1; }

    # The same cut_resettle function used by finish_tmproot, exercised here
    # without deleting the enclosing suite fixture.
    cut_resettle "$ctl" 180 || { cut_fail "the exit-trap settlement could not prove completion"; return 1; }
    [[ " $CUT_PENDING " != *" $ctl "* ]] \
        || { cut_fail "a proved cut was left pending"; return 1; }
    [ -e "$ctl/child.status" ] && [ "$(hs lock-state "$ctl/stage.alive")" = "free" ] \
        || { cut_fail "settlement returned without the stage's status and exit"; return 1; }
}

cut_case "failure path: an unproven cleanup retains everything until a settlement proves completion" \
    cut_unproven cut_unproven_live ""

check  # Structural, read from this file: `trap -p` inside a pipeline or command
# substitution is not reliable across bash versions (3.2 resets traps there).
if grep -qx 'trap finish_tmproot EXIT' "$0" && grep -qx "trap 'exit 130' INT" "$0" \
   && grep -qx "trap 'exit 143' TERM" "$0"; then
    ok "structural check: interruption traps route to proof-requiring settlement"
else
    no "structural check: interruption traps route to proof-requiring settlement" \
       "EXIT/INT/TERM traps are not all routed to finish_tmproot"
fi

# ---------------------------------------------------------------------------
# Identity: refs, upstreams and empty fields
# ---------------------------------------------------------------------------
check
B="$(mksbx backup)"
g -C "$B" init --bare backup.git >/dev/null 2>&1
g -C "$B/wt-clean" remote add backup "$B/backup.git" >/dev/null 2>&1
g -C "$B/wt-clean" push -q -u backup feat-clean >/dev/null 2>&1
if stage "$B" released; then
    out="$(reap "$B")"
    if [ -e "$B/wt-clean" ]; then
        ok "a backup upstream is never reported as the origin ref"
    else
        no "a backup upstream is never reported as the origin ref" \
           "removed while tracking a non-origin remote: $out"
    fi
else
    no "a backup upstream is never reported as the origin ref" "staging failed"
fi

check
B="$(mksbx noupstream)"
g -C "$B/repo" worktree add -q "$B/wt-local" -b feat-local >/dev/null 2>&1
out="$( REAPER_FENCE_HELPER="$HELPER" REAPER_FENCE_PYTHON="$FENCE_PYTHON" \
        "$REAPER" --reap --yes --force --no-color --path "$B/wt-local" 2>&1 )"
if [ ! -e "$B/wt-local" ] && [[ "$out" != *"invalid_ref"* ]]; then
    ok "a branch with no upstream reports an empty remote ref"
else
    no "a branch with no upstream reports an empty remote ref" "present=$([ -e "$B/wt-local" ] && echo y || echo n) out=$out"
fi

check
B="$(mksbx detached)"
head_oid="$(g -C "$B/repo" rev-parse HEAD)"
g -C "$B/repo" worktree add -q --detach "$B/wt-detached" "$head_oid" >/dev/null 2>&1
out="$( REAPER_FENCE_HELPER="$HELPER" REAPER_FENCE_PYTHON="$FENCE_PYTHON" \
        "$REAPER" --reap --yes --force --no-color --path "$B/wt-detached" 2>&1 )"
if [ ! -e "$B/wt-detached" ] && [[ "$out" != *"invalid_ref"* ]]; then
    ok "a detached worktree reports empty local and remote refs"
else
    no "a detached worktree reports empty local and remote refs" "present=$([ -e "$B/wt-detached" ] && echo y || echo n) out=$out"
fi

# ---------------------------------------------------------------------------
# Receipt validation: a zero exit is a claim, not a proof
# ---------------------------------------------------------------------------
# These use a stub guard, which is legitimate here precisely because the subject
# under test is receipt checking in the CONSUMER, not the fence. The stub stands
# in for a guard that lies; no fence behaviour is claimed from it.
stub_guard() {
    {
        printf '#!/bin/sh\n'
        printf 'case "$1" in -c) shift; exec "%s" -c "$@" ;; esac\n' "$FENCE_PYTHON"
        printf '%s\n' "$2"
    } > "$1"
    chmod +x "$1"
}

reap_stub() {
    REAPER_FENCE_HELPER="$HELPER" REAPER_FENCE_PYTHON="$1" \
        "$REAPER" --reap --yes --force --no-color --path "$2" 2>&1
}

receipt_case() {
    local name="$1" stub="$2" body="$3" B
    check
    B="$(mksbx "$name")"
    stub_guard "$stub" "$(printf '%s' "$body" | sed "s#@CAND@#$B/wt-clean#g")"
    local out; out="$(reap_stub "$stub" "$B")"
    if [ -e "$B/wt-clean" ] && [[ "$out" == *"receipt did not prove"* ]]; then
        ok "$name"
    else
        no "$name" "present=$(present "$B") out=$out"
    fi
}

R_OK='{"schemaVersion":1,"outcome":"removed","protected":false,"candidatePath":"@CAND@","localRef":"refs/heads/feat-clean","remoteRef":"refs/heads/feat-clean","removalPath":"force"'

receipt_case "exit 0 with an empty receipt is not success" "$TMPROOT/s1" 'exit 0'
receipt_case "exit 0 with a malformed receipt is not success" "$TMPROOT/s2" 'echo not json; exit 0'
receipt_case "a receipt naming a different candidate is not success" "$TMPROOT/s3" \
  'echo {\"schemaVersion\":1,\"outcome\":\"removed\",\"protected\":false,\"candidatePath\":\"/somewhere/else\",\"localRef\":\"refs/heads/feat-clean\",\"remoteRef\":\"refs/heads/feat-clean\",\"removalPath\":\"force\",\"postcheck\":\"absent\",\"groupLiveness\":\"gone\",\"custody\":\"completed\"}; exit 0'
receipt_case "a receipt whose postcheck is not absent is not success" "$TMPROOT/s4" \
  "echo '$R_OK,\"postcheck\":\"present\",\"groupLiveness\":\"gone\",\"removedResources\":[\"path\"],\"custody\":\"completed\"}'; exit 0"
receipt_case "a receipt with surviving descendants is not success" "$TMPROOT/s5" \
  "echo '$R_OK,\"postcheck\":\"absent\",\"groupLiveness\":\"alive\",\"removedResources\":[\"path\"],\"custody\":\"completed\"}'; exit 0"
receipt_case "a receipt with retained custody is not success" "$TMPROOT/s6" \
  "echo '$R_OK,\"postcheck\":\"absent\",\"groupLiveness\":\"gone\",\"removedResources\":[\"path\"],\"custody\":\"retained\"}'; exit 0"
receipt_case "a receipt with no removedResources is not success" "$TMPROOT/s8" \
  "echo '$R_OK,\"postcheck\":\"absent\",\"groupLiveness\":\"gone\",\"custody\":\"completed\"}'; exit 0"
receipt_case "a receipt proving no path removal is not success" "$TMPROOT/s9" \
  "echo '$R_OK,\"postcheck\":\"absent\",\"groupLiveness\":\"gone\",\"removedResources\":[\"local\"],\"custody\":\"completed\"}'; exit 0"
receipt_case "a receipt with the wrong schema version is not success" "$TMPROOT/s7" \
  "echo '{\"schemaVersion\":2,\"outcome\":\"removed\",\"protected\":false,\"candidatePath\":\"@CAND@\",\"localRef\":\"refs/heads/feat-clean\",\"remoteRef\":\"refs/heads/feat-clean\",\"removalPath\":\"force\",\"postcheck\":\"absent\",\"groupLiveness\":\"gone\",\"custody\":\"completed\"}'; exit 0"

check  # Paths are not always tidy. A sandbox with spaces and shell
# metacharacters proves nothing here splits a word it should have quoted.
B="$(mksbx "odd name (with) spaces & 'quotes'")"
if stage "$B" released; then
    out="$(reap "$B")"
    if [ ! -e "$B/wt-clean" ] && [ "$(record_state "$B")" = "removed" ]; then
        ok "a path with spaces and metacharacters is removed correctly"
    else
        no "a path with spaces and metacharacters is removed correctly" \
           "present=$(present "$B") state=$(record_state "$B") out=$out"
    fi
else
    no "a path with spaces and metacharacters is removed correctly" "staging failed"
fi

# ---------------------------------------------------------------------------
# Unsupported paths stay refused, and stay visibly partial
# ---------------------------------------------------------------------------
check  # A stale lock is debris, and it is now cleared in ONE guarded mutation:
# `worktree remove --force --force`. There is no separate `worktree unlock`, so
# there is no window in which the lock is lifted but the removal was refused.
B="$(mksbx locked)"
if stage "$B" released; then
    g -C "$B/repo" worktree lock "$B/wt-clean" >/dev/null 2>&1
    out="$(reap "$B")"
    if [ ! -e "$B/wt-clean" ] && [ "$(record_state "$B")" = "removed" ]; then
        ok "a stale locked worktree is removed atomically under the guard"
    else
        no "a stale locked worktree is removed atomically under the guard" \
           "present=$(present "$B") state=$(record_state "$B") out=$out"
    fi
else
    no "a stale locked worktree is removed atomically under the guard" "staging failed"
fi

check  # The fence still outranks the lock: a locked worktree that is also
# reserved is protected, and the lock is emphatically not lifted on the way.
B="$(mksbx locked_reserved)"
if stage "$B" active; then
    g -C "$B/repo" worktree lock "$B/wt-clean" >/dev/null 2>&1
    out="$(reap "$B")"
    locked_still="$(g -C "$B/repo" worktree list --porcelain 2>/dev/null | grep -c "^locked")"
    if [ -e "$B/wt-clean" ] && [ "$(record_state "$B")" = "active" ] && [ "$locked_still" -ge 1 ]; then
        ok "a reserved locked worktree is protected and stays locked"
    else
        no "a reserved locked worktree is protected and stays locked" \
           "present=$(present "$B") state=$(record_state "$B") locked=$locked_still out=$out"
    fi
else
    no "a reserved locked worktree is protected and stays locked" "staging failed"
fi

check
B="$(mksbx orphan)"
if stage "$B" released; then
    rm -rf "$B/repo"
    out="$(reap "$B")"
    if [ -e "$B/wt-clean" ] && [[ "$out" == *"fence_orphan_unsupported"* ]]; then
        ok "orphan is refused: unprovable identity protects"
    else
        no "orphan is refused: unprovable identity protects" "present=$(present "$B") out=$out"
    fi
else
    no "orphan is refused: unprovable identity protects" "staging failed"
fi

check
B="$(mksbx tombstone)"
if stage "$B" released; then
    reap "$B" >/dev/null 2>&1
    g -C "$B/repo" worktree add -q "$B/wt-clean" -b feat-again >/dev/null 2>&1
    out="$(reap "$B")"
    [ -e "$B/wt-clean" ] && ok "a tombstone does not clear a resource recreated at the same path" \
        || no "a tombstone does not clear a resource recreated at the same path" "$out"
else
    no "a tombstone does not clear a resource recreated at the same path" "staging failed"
fi

check
B="$(mksbx pruned)"
if stage "$B" released; then
    out="$( REAPER_FENCE_HELPER="$HELPER" REAPER_FENCE_PYTHON="$FENCE_PYTHON" \
            "$REAPER" --reap --yes --force --prune --no-color --path "$B" 2>&1 )"
    if [[ "$out" == *"--prune skipped"* ]] && [ ! -e "$B/wt-clean" ]; then
        ok "--prune is skipped while the guarded removal proceeds"
    else
        no "--prune is skipped while the guarded removal proceeds" "$out"
    fi
else
    no "--prune is skipped while the guarded removal proceeds" "staging failed"
fi

# ---------------------------------------------------------------------------
# Structural: no unguarded removal primitive may reappear
# ---------------------------------------------------------------------------
code() { grep -vE '^[[:space:]]*#' "$REAPER"; }

check
n="$(code | grep -c 'worktree remove')"
[ "$n" -eq 1 ] && ok "exactly one worktree-removal command is constructed" \
               || no "exactly one worktree-removal command is constructed" "found $n"

check
[ "$(code | grep -c 'fence_guard_exec')" -ge 2 ] \
    && ok "the removal command is handed to the guard" \
    || no "the removal command is handed to the guard" "fence_guard_exec not invoked"

check
n="$(code | grep -c 'worktree unlock')"
[ "$n" -eq 0 ] && ok "no worktree-unlock mutation remains" \
               || no "no worktree-unlock mutation remains" "found $n"

check
if code | grep -q 'rm -rf .*\$wt\|rm -rf .*\$cand\|rmdir'; then
    no "no unguarded recursive delete of a candidate remains" "found one"
else
    ok "no unguarded recursive delete of a candidate remains"
fi

summary
