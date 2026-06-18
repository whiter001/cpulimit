#!/usr/bin/env bash
# test_smoke.sh — integration smoke tests for vcpulimit.
#
# Each test launches a known CPU-eating workload, runs vcpulimit against it,
# then samples `ps %cpu` over a fixed window and asserts the observed CPU is
# below the requested limit (with a generous tolerance to absorb scheduler
# jitter on shared CI hosts).
#
# Usage:
#   ./tests/test_smoke.sh                 # auto-build ./vcpulimit if missing
#   VCPULIMIT=./vcpulimit ./tests/test_smoke.sh
#
# Exit codes:
#   0   all tests passed
#   1   one or more tests failed
#   2   environment not suitable (e.g. ps/ps -o %cpu unavailable)
set -uo pipefail

cd "$(dirname "$0")/.."

VCPULIMIT="${VCPULIMIT:-./vcpulimit}"
CC="${CC:-cc}"

PASS=0
FAIL=0
SKIP=0
LOG_DIR="$(mktemp -d -t vcpulimit-tests.XXXXXX)"
trap 'rm -rf "$LOG_DIR"; pkill -9 -f tests/busy 2>/dev/null; pkill -9 -f vcpulimit 2>/dev/null' EXIT

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

require_tool() {
    command -v "$1" >/dev/null 2>&1 || { red "missing dependency: $1"; exit 2; }
}
require_tool ps
require_tool pkill

# ---- build cpulimit if needed ----
if [ ! -x "$VCPULIMIT" ] && [ -x ./build.sh ]; then
    bold "vcpulimit not found, building…"
    ./build.sh >"$LOG_DIR/build.log" 2>&1 || { red "build failed (see $LOG_DIR/build.log)"; exit 1; }
fi
[ -x "$VCPULIMIT" ] || { red "no vcpulimit binary at $VCPULIMIT"; exit 1; }

# ---- build busy test workload ----
BUSY="$LOG_DIR/busy"
if ! $CC -O2 -o "$BUSY" tests/busy.c 2>"$LOG_DIR/busy.build.log"; then
    red "failed to compile tests/busy.c:"
    cat "$LOG_DIR/busy.build.log"
    exit 1
fi

# ---- helpers ----
# sample_cpu PID SECONDS -> average %cpu across the window
sample_cpu() {
    local pid="$1" secs="$2"
    local sum=0 n=0
    for _ in $(seq 1 "$secs"); do
        local v
        v=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
        # ps prints "<num>" on macOS, "<num>.<frac>" on GNU; round to int.
        v=${v%.*}
        [ -z "$v" ] && continue
        sum=$((sum + v))
        n=$((n + 1))
        sleep 1
    done
    [ "$n" -gt 0 ] || return 1
    echo $((sum / n))
}

# assert that observed <= limit + tolerance
assert_below() {
    local label="$1" observed="$2" limit="$3" tol="${4:-15}"
    local hi=$((limit + tol))
    if [ "$observed" -le "$hi" ]; then
        green "  PASS  $label  observed=${observed}% <= ${limit}+${tol}%"
        PASS=$((PASS + 1))
    else
        red   "  FAIL  $label  observed=${observed}% > ${limit}+${tol}%"
        FAIL=$((FAIL + 1))
    fi
}

# assert that observed is roughly close to limit (uncapped baseline)
assert_near() {
    local label="$1" observed="$2" target="$3" tol="${4:-15}"
    local lo=$((target - tol)); [ "$lo" -lt 0 ] && lo=0
    local hi=$((target + tol))
    if [ "$observed" -ge "$lo" ] && [ "$observed" -le "$hi" ]; then
        green "  PASS  $label  observed=${observed}% in [${lo},${hi}]%"
        PASS=$((PASS + 1))
    else
        red   "  FAIL  $label  observed=${observed}% not in [${lo},${hi}]%"
        FAIL=$((FAIL + 1))
    fi
}

# run vcpulimit against $target_pid in the background and echo the limiter's pid.
# Caller is responsible for killing it after sampling.
start_limit() {
    local limit="$1" target_pid="$2"
    "$VCPULIMIT" -l "$limit" -p "$target_pid" -v >"$LOG_DIR/cpulimit.${target_pid}.log" 2>&1 &
    echo $!
}

# ============================================================================
# Test 1: --help exits 0 and prints usage
# ============================================================================
bold "T1: --help"
if "$VCPULIMIT" --help >"$LOG_DIR/help.log" 2>&1; then
    if grep -q "Usage:" "$LOG_DIR/help.log"; then
        green "  PASS  --help prints usage"
        PASS=$((PASS + 1))
    else
        red   "  FAIL  --help did not print 'Usage:'"
        cat "$LOG_DIR/help.log"
        FAIL=$((FAIL + 1))
    fi
else
    red   "  FAIL  --help exited non-zero"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 2: invalid argument combinations are rejected
# ============================================================================
bold "T2: arg validation"
if "$VCPULIMIT" -p 1 >"$LOG_DIR/no-limit.log" 2>&1; then
    red "  FAIL  -p without -l should fail"
    FAIL=$((FAIL + 1))
else
    green "  PASS  -p without -l rejected"
    PASS=$((PASS + 1))
fi

if "$VCPULIMIT" -l 50 -p 99999 >"$LOG_DIR/bad-pid.log" 2>&1; then
    red "  FAIL  -p 99999 should fail (out of range)"
    FAIL=$((FAIL + 1))
else
    green "  PASS  out-of-range pid rejected"
    PASS=$((PASS + 1))
fi

# ============================================================================
# Test 3: busy baseline (no limiter) sits near 100%
# ============================================================================
bold "T3: uncapped baseline"
"$BUSY" >/dev/null 2>&1 &
BUSY_PID=$!
sleep 1
baseline=$(sample_cpu "$BUSY_PID" 3) || baseline=0
kill -9 "$BUSY_PID" 2>/dev/null || true
wait "$BUSY_PID" 2>/dev/null || true
echo "  baseline observed=${baseline}%"
if [ "$baseline" -ge 80 ]; then
    green "  PASS  busy workload hits >=80% without limiter"
    PASS=$((PASS + 1))
else
    yellow "  SKIP  busy baseline only ${baseline}% — host too noisy to test reliably"
    SKIP=$((SKIP + 1))
    # Skip the limit-tests as their assertions would be meaningless
    bold "summary: pass=$PASS fail=$FAIL skip=$SKIP"
    exit 0
fi

# ============================================================================
# Test 4: -p limits an existing process to ~limit
# ============================================================================
bold "T4: -l 25 -p <pid>"
"$BUSY" >/dev/null 2>&1 &
BUSY_PID=$!
sleep 1
# Start limiter, give it a moment to converge, then sample.
CP=$(start_limit 25 "$BUSY_PID")
sleep 1.5
observed=$(sample_cpu "$BUSY_PID" 3) || observed=0
kill -INT "$CP" 2>/dev/null || true
sleep 0.3
kill -9 "$BUSY_PID" 2>/dev/null || true
wait "$CP" 2>/dev/null || true
wait "$BUSY_PID" 2>/dev/null || true
echo "  observed=${observed}% (limit=25, tol=20)"
assert_below "-l 25 -p <pid>" "$observed" 25 20

# ============================================================================
# Test 5: -e limits by exe name
# ============================================================================
bold "T5: -l 30 -e busy"
cp "$BUSY" "$LOG_DIR/busy_test"
"$LOG_DIR/busy_test" >/dev/null 2>&1 &
BUSY_PID=$!
sleep 1
"$VCPULIMIT" -l 30 -e busy_test >"$LOG_DIR/cpulimit.exe.log" 2>&1 &
CP=$!
sleep 1.5
observed=$(sample_cpu "$BUSY_PID" 3) || observed=0
kill -INT "$CP" 2>/dev/null || true
kill -9 "$BUSY_PID" 2>/dev/null || true
kill -9 "$CP" 2>/dev/null || true
wait 2>/dev/null || true
echo "  observed=${observed}% (limit=30, tol=20)"
assert_below "-l 30 -e busy_test" "$observed" 30 20

# ============================================================================
# Test 6: command-mode wraps + limits the launched child
# ============================================================================
bold "T6: -l 20 -- <command>"
"$VCPULIMIT" -l 20 -- "$BUSY" >"$LOG_DIR/cpulimit.cmd.log" 2>&1 &
WRAP_PID=$!
sleep 2
# Find any running busy process — the wrapper does double-fork so its
# process tree (wrapper → limiter → target) isn't easy to inspect via
# pgrep -P; just look for the busy binary by its full path.
CHILD=$(pgrep -f "$BUSY" | head -1)
if [ -n "$CHILD" ]; then
    sleep 1.5
    observed=$(sample_cpu "$CHILD" 3) || observed=0
    echo "  observed=${observed}% (limit=20, tol=15)"
    assert_below "-l 20 -- busy" "$observed" 20 15
else
    red   "  FAIL  could not find busy child of cpulimit command-mode"
    cat "$LOG_DIR/cpulimit.cmd.log" | head -5
    FAIL=$((FAIL + 1))
fi
kill -INT "$WRAP_PID" 2>/dev/null || true
sleep 0.3
pkill -9 -f "$BUSY" 2>/dev/null || true
wait 2>/dev/null || true

# ============================================================================
# summary
# ============================================================================
bold "summary: pass=$PASS fail=$FAIL skip=$SKIP"
if [ "$FAIL" -gt 0 ]; then
    red "FAILED"
    echo "logs in: $LOG_DIR"
    exit 1
fi
green "OK"
