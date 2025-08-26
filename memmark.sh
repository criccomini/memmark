#!/usr/bin/env bash
# memmark.sh - Sample memory usage of a process and all descendants, output CSV, optional chart
# Portable to macOS and Linux. Default is fast mode; Linux smaps metrics only with --smaps.

set -euo pipefail
IFS=$' 	\n'
LC_ALL=C

# Globals used by traps
ROOT_PID=""
LAUNCHED=0
STOP_REQUESTED=0
INT_COUNT=0

VERSION="0.1.0"

usage() {
  cat <<'USAGE'
memmark - sample memory usage over time

Usage:
  memmark.sh --pid <PID> [options]
  memmark.sh [options] -- <COMMAND ...>

Options:
  --pid <PID>            Attach to an existing PID (mutually exclusive with command).
  --interval <DUR>      Sampling interval (e.g., 200ms, 1s, 2m). Default: 1s.
  --duration <DUR>      Maximum duration to run (e.g., 30s, 5m). Default: until target exits.
  --out <PATH>          CSV output path. Use - for stdout. Default: memmark.csv
  --smaps               Linux: enable PSS/swap via /proc/<pid>/smaps (higher overhead; off by default).
  --chart <PNG>         If set and gnuplot is available, generate chart to given PNG path.
  -h, --help            Show this help.

CSV columns:
  timestamp,unix_ms,root_pid,pid_count,rss_kib,vsz_kib,swap_kib,pss_kib,phys_footprint_kib,mapped_regions
USAGE
}

log() { printf '[memmark] %s\n' "$*" >&2; }
warn() { printf '[memmark][warn] %s\n' "$*" >&2; }
err() { printf '[memmark][error] %s\n' "$*" >&2; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Parse human durations into milliseconds. Supports: ms, s, m, h. Allows decimals.
# e.g., 200ms -> 200; 1s -> 1000; 2.5s -> 2500; 2m -> 120000
parse_duration_to_ms() {
  local input="$1"
  if [[ -z "$input" ]]; then echo 0; return; fi
  local num unit
  if [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)(ms|s|m|h)$ ]]; then
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[3]}"
  elif [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)$ ]]; then
    # Treat bare number as seconds
    num="${BASH_REMATCH[1]}"; unit="s"
  else
    err "Invalid duration: $input"; exit 2
  fi
  case "$unit" in
    ms) awk -v n="$num" 'BEGIN{printf "%d", n}' ;;
    s)  awk -v n="$num" 'BEGIN{printf "%d", n*1000}' ;;
    m)  awk -v n="$num" 'BEGIN{printf "%d", n*60*1000}' ;;
    h)  awk -v n="$num" 'BEGIN{printf "%d", n*3600*1000}' ;;
    *)  echo 0 ;;
  esac
}

# Current Unix epoch milliseconds, with fallbacks for macOS without GNU date
now_ms() {
  if have_cmd python3; then python3 - <<'PY'
import time
print(int(time.time()*1000))
PY
  elif have_cmd python; then python - <<'PY'
import time
print(int(time.time()*1000))
PY
  elif have_cmd perl; then perl -MTime::HiRes=time -e 'printf("%d\n", int(time()*1000))'
  elif date +%s%3N >/dev/null 2>&1; then date +%s%3N
  else
    # Fallback seconds only
    printf "%d\n" $(( $(date +%s) * 1000 ))
  fi
}

iso8601_utc() {
  # Use UTC Zulu timestamp to match README examples
  if have_cmd gdate; then gdate -u +%Y-%m-%dT%H:%M:%SZ || true; else date -u +%Y-%m-%dT%H:%M:%SZ || true; fi
}

join_by_comma() { local IFS=','; echo "$*"; }

# Return 0 if pid is alive, else 1
pid_alive() { kill -0 "$1" 2>/dev/null; }

OS=$(uname -s)
IS_DARWIN=0; IS_LINUX=0
case "$OS" in
  Darwin) IS_DARWIN=1 ;;
  Linux)  IS_LINUX=1  ;;
  *) warn "Unsupported OS $OS. Some features may not work." ;;
 esac

# Collect descendant PIDs including root, using ps pid/ppid pairs (portable)
collect_descendants() {
  local root="$1"
  local pairs
  pairs=$(ps -eo pid=,ppid= || true)
  # Initialize set: space-padded string for quick membership checks
  local set=" $root "
  local added=1
  while [[ $added -eq 1 ]]; do
    added=0
    while read -r pid ppid; do
      [[ -z "$pid" || -z "$ppid" ]] && continue
      if [[ "$set" == *" $ppid "* && "$set" != *" $pid "* ]]; then
        set+="$pid "
        added=1
      fi
    done <<<"$pairs"
  done
  # Emit newline-separated PIDs
  printf "%s\n" $set | awk 'NF>0 && $1 ~ /^[0-9]+$/{print $1}'
}

sum_ps_rss_vsz_kib() {
  # Args: newline-separated PID list
  local pids=("$@")
  if [[ ${#pids[@]} -eq 0 ]]; then echo "0 0"; return; fi
  # Build comma-separated list for ps -p (portable on macOS & Linux)
  local csv
  csv=$(printf ",%s" "${pids[@]}"); csv=${csv:1}
  # Sum rss and vsz; both are in KiB on Linux and macOS
  local rss_vsz
  rss_vsz=$(ps -o rss=,vsz= -p "$csv" 2>/dev/null | awk '{rss+=$1; vsz+=$2} END{printf "%d %d", rss+0, vsz+0}') || rss_vsz="0 0"
  echo "$rss_vsz"
}

linux_smaps_pss_swap() {
  # Args: newline-separated PID list
  local total_pss=0 total_swap=0
  local pid
  for pid in "$@"; do
    local smap="/proc/$pid/smaps"
    if [[ -r "$smap" ]]; then
      # Sum Pss and Swap in KiB
      local pss swap
      pss=$(awk '/^Pss:/ {s+=$2} END{printf "%d", s+0}' "$smap" 2>/dev/null || echo 0)
      swap=$(awk '/^Swap:/ {s+=$2} END{printf "%d", s+0}' "$smap" 2>/dev/null || echo 0)
      total_pss=$(( total_pss + pss ))
      total_swap=$(( total_swap + swap ))
    fi
  done
  printf "%d %d\n" "$total_pss" "$total_swap"
}

linux_mapped_regions() {
  local total=0 pid
  for pid in "$@"; do
    local maps="/proc/$pid/maps"
    if [[ -r "$maps" ]]; then
      local c
      c=$(wc -l < "$maps" 2>/dev/null || echo 0)
      total=$(( total + c ))
    fi
  done
  echo "$total"
}

on_sigint() {
  STOP_REQUESTED=1
  INT_COUNT=$((INT_COUNT+1))
  # Only forward to launched commands; do not kill attached PIDs we didn't start.
  if [[ $LAUNCHED -eq 1 && -n "$ROOT_PID" ]]; then
    local sig="INT"
    if [[ $INT_COUNT -ge 3 ]]; then sig="KILL"; elif [[ $INT_COUNT -ge 2 ]]; then sig="TERM"; fi
    kill -"$sig" "$ROOT_PID" 2>/dev/null || true
  fi
}

on_sigterm() {
  STOP_REQUESTED=1
  if [[ $LAUNCHED -eq 1 && -n "$ROOT_PID" ]]; then
    kill -TERM "$ROOT_PID" 2>/dev/null || true
  fi
}

# macOS: attempt to sum physical footprint and region counts via vmmap -summary
macos_vmmap_footprint_regions() {
  local total_kib=0 total_regions=0 pid
  if ! have_cmd vmmap; then echo "0 0"; return; fi
  for pid in "$@"; do
    # vmmap -summary can be slow; best-effort parsing
    local out
    out=$(vmmap -summary "$pid" 2>/dev/null || true)
    [[ -z "$out" ]] && continue

    # Physical Footprint: handle formats like "120.5M", "120.5 MB", "120.5MiB"
    local pf_line pf_token num unit kib
    pf_line=$(printf "%s\n" "$out" | awk 'tolower($0) ~ /physical[[:space:]]+footprint/ {print; exit}')
    if [[ -n "$pf_line" ]]; then
      pf_token=$(printf "%s\n" "$pf_line" | grep -Eio '[0-9]+([.,][0-9]+)?[[:space:]]*(k|m|g|t)i?b?' | head -n1 | tr '[:upper:]' '[:lower:]' | tr -d ' ')
      if [[ -n "$pf_token" ]]; then
        pf_token=${pf_token/,/.}
        num=$(printf "%s\n" "$pf_token" | grep -Eo '^[0-9]+(\.[0-9]+)?')
        unit=$(printf "%s\n" "$pf_token" | sed -E 's/^[0-9]+(\.[0-9]+)?//')
        case "$unit" in
          k|kb|kib|"") kib=$(awk -v n="$num" 'BEGIN{printf "%d", n}') ;;
          m|mb|mib)     kib=$(awk -v n="$num" 'BEGIN{printf "%d", n*1024}') ;;
          g|gb|gib)     kib=$(awk -v n="$num" 'BEGIN{printf "%d", n*1048576}') ;;
          t|tb|tib)     kib=$(awk -v n="$num" 'BEGIN{printf "%d", n*1073741824}') ;;
          *)            kib="" ;;
        esac
        [[ -n "$kib" ]] && total_kib=$(( total_kib + kib ))
      fi
    fi

    # Regions count (best effort): try to find a numeric value on any line mentioning 'regions'
    local reg
    reg=$(printf "%s\n" "$out" | awk 'tolower($0) ~ /regions/ {print}' | grep -Eo '[0-9]+' | head -n1 || true)
    if [[ -n "$reg" ]]; then
      total_regions=$(( total_regions + reg ))
    fi
  done
  printf "%d %d\n" "$total_kib" "$total_regions"
}

write_header_if_needed() {
  local path="$1"
  if [[ "$path" == "-" ]]; then
    echo "timestamp,unix_ms,root_pid,pid_count,rss_kib,vsz_kib,swap_kib,pss_kib,phys_footprint_kib,mapped_regions"
    return
  fi
  if [[ ! -f "$path" || ! -s "$path" ]]; then
    echo "timestamp,unix_ms,root_pid,pid_count,rss_kib,vsz_kib,swap_kib,pss_kib,phys_footprint_kib,mapped_regions" >"$path"
  fi
}

append_csv_row() {
  local path="$1"; shift
  local row="$1"
  if [[ "$path" == "-" ]]; then
    echo "$row"
  else
    echo "$row" >>"$path"
  fi
}

# Generate a chart via gnuplot using csv at $1 to PNG at $2
generate_chart() {
  local csv="$1" png="$2" title="memmark"
  if ! have_cmd gnuplot; then warn "gnuplot not found; skipping chart"; return; fi
  if [[ ! -s "$csv" ]]; then warn "CSV '$csv' missing or empty; skipping chart"; return; fi
  gnuplot -persist <<GP
set datafile separator ','
set terminal pngcairo size 1280,720
set output '${png}'
set grid
set key outside
set xdata time
set timefmt '%s'
set format x '%H:%M:%S'
set title '${title}'
plot \
  '${csv}' using (column(2)/1000):5 with lines lw 2 title 'RSS KiB', \
  '${csv}' using (column(2)/1000):6 with lines lw 2 title 'VSZ KiB', \
  '${csv}' using (column(2)/1000):7 with lines lw 2 title 'SWAP KiB'
GP
}

sleep_seconds() {
  local seconds=$1
  if have_cmd usleep; then
    usleep $(awk -v s="$seconds" 'BEGIN{printf "%d", s*1000000}')
  else
    sleep "$seconds"
  fi
}

main() {
  local root_pid="" out_path="memmark.csv" interval_ms=1000 duration_ms=0 do_smaps=0 chart_path="" mode=""
  local -a cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pid)       root_pid="${2:-}"; shift 2 ;;
      --interval)  interval_ms=$(parse_duration_to_ms "${2:-}"); shift 2 ;;
      --duration)  duration_ms=$(parse_duration_to_ms "${2:-}"); shift 2 ;;
      --out)       out_path="${2:-}"; shift 2 ;;
      --smaps)     do_smaps=1; shift ;;
      --chart)     chart_path="${2:-}"; shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      --)          shift; cmd=("$@"); break ;;
      *)           err "Unknown argument: $1"; usage; exit 2 ;;
    esac
  done

  if [[ -n "$root_pid" && ${#cmd[@]} -gt 0 ]]; then err "--pid is mutually exclusive with command"; exit 2; fi
  if [[ -z "$root_pid" && ${#cmd[@]} -eq 0 ]]; then err "Provide --pid or a command after -- (see --help for more details)"; exit 2; fi

  local launched=0 cmd_exit=0
  if [[ ${#cmd[@]} -gt 0 ]]; then
    # Launch command in background
    ("${cmd[@]}") &
    root_pid=$!
    launched=1
    log "Launched command as PID $root_pid"
  else
    if ! pid_alive "$root_pid"; then err "PID $root_pid not running"; exit 1; fi
  fi

  # Export to globals for trap handlers
  ROOT_PID="$root_pid"
  LAUNCHED=$launched

  # Install traps to forward signals and stop sampling
  trap on_sigint INT
  trap on_sigterm TERM

  write_header_if_needed "$out_path"

  local start_ms now end_ms
  start_ms=$(now_ms)
  if [[ $duration_ms -gt 0 ]]; then end_ms=$(( start_ms + duration_ms )); else end_ms=0; fi
  local interval_s
  interval_s=$(awk -v ms="$interval_ms" 'BEGIN{printf "%.3f", ms/1000.0}')

  # Sampling loop
  while :; do
    # Stop on user interrupt/termination
    if [[ $STOP_REQUESTED -eq 1 ]]; then break; fi
    if [[ $end_ms -gt 0 ]]; then
      now=$(now_ms)
      if [[ $now -ge $end_ms ]]; then break; fi
    fi
    # If tracking existing PID, exit when it dies
    if ! pid_alive "$root_pid"; then break; fi

    # Gather PID tree
    # Collect descendants into array (compatible with bash 3.2)
    local pids=()
    while IFS= read -r _pid; do
      [[ -n "$_pid" ]] && pids+=("$_pid")
    done < <(collect_descendants "$root_pid")
    if [[ ${#pids[@]} -eq 0 ]]; then break; fi

    local pid_count=${#pids[@]}

    # RSS/VSZ
    local rss_vsz rss_kib vsz_kib
    rss_vsz=$(sum_ps_rss_vsz_kib "${pids[@]}") || rss_vsz="0 0"
    rss_kib=${rss_vsz%% *}
    vsz_kib=${rss_vsz##* }

    # Optional metrics
    local pss_kib="" swap_kib="" phys_kib="" regions=""
    if [[ $IS_LINUX -eq 1 ]]; then
      if [[ $do_smaps -eq 1 ]]; then
        read -r pss_kib swap_kib < <(linux_smaps_pss_swap "${pids[@]}") || { pss_kib=""; swap_kib=""; }
      fi
      regions=$(linux_mapped_regions "${pids[@]}") || regions=""
    elif [[ $IS_DARWIN -eq 1 ]]; then
      read -r phys_kib regions < <(macos_vmmap_footprint_regions "${pids[@]}") || { phys_kib=""; regions=""; }
    fi

    local ts_iso ts_ms
    ts_iso=$(iso8601_utc)
    ts_ms=$(now_ms)

    local row
    row=$(printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s" \
      "$ts_iso" "$ts_ms" "$root_pid" "$pid_count" \
      "${rss_kib:-}" "${vsz_kib:-}" "${swap_kib:-}" "${pss_kib:-}" "${phys_kib:-}" "${regions:-}")

    append_csv_row "$out_path" "$row"

    # Sleep; but if duration is near, cap sleep
    if [[ $end_ms -gt 0 ]]; then
      now=$(now_ms)
      if [[ $now -ge $end_ms ]]; then break; fi
      local remain_ms=$(( end_ms - now ))
      # Convert remain to seconds and cap at interval_s
      local remain_s
      remain_s=$(awk -v ms="$remain_ms" 'BEGIN{printf "%.3f", (ms<0?0:ms)/1000.0}')
      # Bash can't directly min floats; call awk
      local sleep_s
      sleep_s=$(awk -v a="$interval_s" -v b="$remain_s" 'BEGIN{printf "%.3f", (a<b)?a:b}')
      sleep_seconds "$sleep_s"
    else
      sleep_seconds "$interval_s"
    fi
  done

  # Wait for command completion and propagate exit code
  if [[ $launched -eq 1 ]]; then
    if wait "$root_pid" 2>/dev/null; then cmd_exit=$?; else cmd_exit=0; fi
  fi

  # Generate chart if requested
  if [[ -n "$chart_path" ]]; then
    if [[ "$out_path" == "-" ]]; then
      warn "Cannot chart from stdout; use --out <file>"
    else
      generate_chart "$out_path" "$chart_path" || warn "Chart generation failed"
    fi
  fi

  if [[ $launched -eq 1 ]]; then exit "$cmd_exit"; else exit 0; fi
}

main "$@"
