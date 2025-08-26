#!/usr/bin/env bash
# tests/test.sh - Smoke tests for memmark.sh
# Verifies core behaviors on macOS and Linux with graceful skips for optional features.

# Intentionally do not set -e; we want to continue after failures and report.
set -u
IFS=$' \t\n'
LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
MEMMARK="$REPO_DIR/memmark.sh"
TESTDIR="$SCRIPT_DIR"
OS=$(uname -s)
IS_DARWIN=0; IS_LINUX=0
case "$OS" in
  Darwin) IS_DARWIN=1 ;;
  Linux)  IS_LINUX=1  ;;
  *) : ;;
esac

HEADER="timestamp,unix_ms,root_pid,pid_count,rss_kib,vsz_kib,swap_kib,pss_kib,phys_footprint_kib,mapped_regions"

PASS=0
FAIL=0
SKIP=0
TOT=0
SKIPPED=0

note() { printf '[test] %s\n' "$*"; }
pass() { printf '\e[32mPASS\e[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\e[31mFAIL\e[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '\e[33mSKIP\e[0m %s\n' "$*"; SKIP=$((SKIP+1)); SKIPPED=1; }

cleanup_artifacts() {
  rm -f "$TESTDIR"/tmp_*.csv "$TESTDIR"/tmp_*.png 2>/dev/null || true
}

require_file() {
  [[ -f "$1" ]] || { fail "File not found: $1"; return 1; }
}

check_header() {
  local f="$1"
  local head
  head=$(head -n1 "$f" 2>/dev/null || echo '')
  [[ "$head" == "$HEADER" ]]
}

check_columns_count() {
  local f="$1"
  awk -F, 'NR>1 && NF!=10 {bad++} END{exit bad>0?1:0}' "$f"
}

check_unix_ms_monotonic() {
  local f="$1"
  awk -F, 'NR==2{prev=$2;next} NR>2{if($2<prev){exit 1} prev=$2} END{exit 0}' "$f"
}

csv_row_count() { wc -l < "$1" | awk '{print $1+0}'; }

run_test() {
  local name="$1"; shift
  TOT=$((TOT+1))
  SKIPPED=0
  if "$@"; then
    if [[ $SKIPPED -eq 0 ]]; then pass "$name"; fi
  else
    : # failure details should already be printed by test via fail()
  fi
}

# Tests

test_help() {
  local out
  out=$("$MEMMARK" --help 2>&1)
  local ec=$?
  [[ $ec -eq 0 ]] || { fail "--help exit code=$ec"; return 1; }
  echo "$out" | grep -q "Usage:" || { fail "--help missing Usage"; return 1; }
  return 0
}

test_no_args_error() {
  local out ec
  out=$("$MEMMARK" 2>&1); ec=$?
  [[ $ec -eq 2 ]] || { fail "no-args expected exit 2, got $ec"; return 1; }
  echo "$out" | grep -qi "Provide --pid or a command" || { fail "no-args error message mismatch"; return 1; }
  return 0
}

test_launch_mode_basic() {
  local f="$TESTDIR/tmp_launch.csv"
  "$MEMMARK" --interval 200ms --duration 1000ms --out "$f" -- sleep 0.5 >/dev/null 2>&1
  require_file "$f" || return 1
  check_header "$f" || { fail "header mismatch"; return 1; }
  [[ $(csv_row_count "$f") -ge 2 ]] || { fail "expected at least 2 rows"; return 1; }
  check_columns_count "$f" || { fail "column count != 10"; return 1; }
  check_unix_ms_monotonic "$f" || { fail "unix_ms not monotonic"; return 1; }
  return 0
}

test_attach_mode_basic() {
  local f="$TESTDIR/tmp_attach.csv"
  (sleep 1.2) & local spid=$!
  "$MEMMARK" --pid "$spid" --interval 200ms --duration 800ms --out "$f" >/dev/null 2>&1
  require_file "$f" || return 1
  local rp
  rp=$(awk -F, 'NR==2{print $3}' "$f")
  [[ "$rp" == "$spid" ]] || { fail "root_pid $rp != $spid"; return 1; }
  return 0
}

test_stdout_out() {
  local f="$TESTDIR/tmp_stdout.csv"
  "$MEMMARK" --interval 200ms --duration 600ms --out - -- sleep 0.2 > "$f" 2>/dev/null
  require_file "$f" || return 1
  check_header "$f" || { fail "stdout header mismatch"; return 1; }
  return 0
}

test_chart_optional() {
  if ! command -v gnuplot >/dev/null 2>&1; then
    skip "gnuplot not found"; return 0
  fi
  local csv="$TESTDIR/tmp_chart.csv" png="$TESTDIR/tmp_chart.png"
  "$MEMMARK" --interval 200ms --duration 800ms --out "$csv" --chart "$png" -- sleep 0.5 >/dev/null 2>&1
  require_file "$csv" || return 1
  require_file "$png" || { fail "chart png missing"; return 1; }
  [[ -s "$png" ]] || { fail "chart png is empty"; return 1; }
  return 0
}

# Linux-only optional smaps
test_linux_smaps_optional() {
  if [[ $IS_LINUX -ne 1 ]]; then skip "not Linux"; return 0; fi
  local f="$TESTDIR/tmp_smaps.csv"
  (sleep 1.0) & local spid=$!
  # ensure smaps readable for at least one PID
  if [[ ! -r "/proc/$spid/smaps" ]]; then skip "/proc/$spid/smaps not readable"; return 0; fi
  "$MEMMARK" --pid "$spid" --interval 200ms --duration 600ms --smaps --out "$f" >/dev/null 2>&1
  require_file "$f" || return 1
  # Expect at least one row with digits in swap_kib (col7) or pss_kib (col8)
  awk -F, 'NR>1 && ($7 ~ /^[0-9]+$/ || $8 ~ /^[0-9]+$/){ok=1} END{exit ok?0:1}' "$f" || { fail "smaps columns empty"; return 1; }
  return 0
}

# macOS-only optional vmmap presence
test_macos_vmmap_columns() {
  if [[ $IS_DARWIN -ne 1 ]]; then skip "not macOS"; return 0; fi
  local f="$TESTDIR/tmp_vmmap.csv"
  if ! command -v vmmap >/dev/null 2>&1; then
    # On macOS without vmmap, columns should still be present as zeros/blank; just verify CSV shape
    "$MEMMARK" --interval 200ms --duration 600ms --out "$f" -- sleep 0.3 >/dev/null 2>&1
    require_file "$f" || return 1
    check_columns_count "$f" || { fail "csv columns count != 10"; return 1; }
    return 0
  fi
  (sleep 1.0) & local spid=$!
  "$MEMMARK" --pid "$spid" --interval 200ms --duration 600ms --out "$f" >/dev/null 2>&1
  require_file "$f" || return 1
  # Columns 9 and 10 should be digits (could be 0)
  awk -F, 'NR>1 && $9 ~ /^[0-9]+$/ && $10 ~ /^[0-9]+$/ {ok=1} END{exit ok?0:1}' "$f" || { fail "vmmap columns not numeric"; return 1; }
  return 0
}

main() {
  note "Running memmark tests from $SCRIPT_DIR"
  cleanup_artifacts

  run_test "help" test_help
  run_test "no-args-error" test_no_args_error
  run_test "launch-mode" test_launch_mode_basic
  run_test "attach-mode" test_attach_mode_basic
  run_test "stdout-out" test_stdout_out
  run_test "chart-optional" test_chart_optional
  run_test "linux-smaps-optional" test_linux_smaps_optional
  run_test "macos-vmmap-columns" test_macos_vmmap_columns

  note "Summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP TOTAL=$TOT"
  cleanup_artifacts
  [[ $FAIL -eq 0 ]]
}

main "$@"
