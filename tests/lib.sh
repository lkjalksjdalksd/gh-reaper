#!/usr/bin/env bash
#
# Shared test scaffolding: reporting, an offline-friendly git, and the sandbox
# both suites build. Sourced, never executed.

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
RUN=0; PASS=0; FAIL=0

ok()   { printf "${GREEN}PASS${NC} %s\n" "$1"; PASS=$((PASS+1)); }
no()   { printf "${RED}FAIL${NC} %s\n  -> %s\n" "$1" "$2"; FAIL=$((FAIL+1)); }
check(){ RUN=$((RUN+1)); }

summary() {
    echo
    printf "Tests run: %d   ${GREEN}passed: %d${NC}   ${RED}failed: %d${NC}\n" \
        "$RUN" "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
}

# Local git that works offline with file:// remotes.
g() {
    command git \
        -c init.defaultBranch=main \
        -c user.email=test@example.com -c user.name=test \
        -c advice.detachedHead=false \
        -c protocol.file.allow=always "$@"
}

# A repo with a bare origin and one pushed worktree on feat-clean.
#
# $1 is an absolute directory to build in; it must already be its own realpath,
# because the fence helper canonicalises every path it is given and refuses one
# that is not (on macOS /tmp is a symlink to /private/tmp).
mk_sandbox() {
    local b="$1"
    mkdir -p "$b"
    (
        cd "$b" || exit 1
        g init --bare remote.git >/dev/null
        g init repo >/dev/null
        cd repo || exit 1
        g remote add origin "$b/remote.git"
        echo hi > a.txt; g add a.txt; g commit -qm init
        g push -q -u origin main
        g worktree add -q ../wt-clean -b feat-clean
        cd ../wt-clean || exit 1
        echo c > c.txt; g add c.txt; g commit -qm work
        g push -q -u origin feat-clean
    ) >/dev/null 2>&1
    printf '%s' "$b"
}

# A temporary directory that is already its own realpath.
mk_realpath_tmpdir() { (cd "$(mktemp -d)" && pwd -P); }
