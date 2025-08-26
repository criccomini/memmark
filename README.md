# memmark

Single-file Bash tool to sample memory usage of a target process and its entire descendant tree over time. It writes a CSV file and can optionally render charts if gnuplot is installed.

## Features

- CSV output of memory usage over time
- Accepts a PID to attach to, or a command to launch and track
- Aggregates memory across all child processes (recursively)
- Portable: macOS and Linux (graceful fallbacks per-OS)
- Optional charts via gnuplot (if installed)

## What memmark measures

Memmark samples once per interval and sums metrics across the tracked process and all of its descendants:

- rss_kib: Resident Set Size sum in KiB (macOS+Linux via `ps`)
- vsz_kib: Virtual memory size sum in KiB (macOS+Linux via `ps`)
- swap_kib: Swap in KiB (Linux via `/proc/*/smaps` when `--smaps` is enabled; blank on macOS)
- pss_kib: Proportional Set Size in KiB (Linux via `/proc/*/smaps` when `--smaps` is enabled)
- phys_footprint_kib: macOS Physical Footprint (via `vmmap -summary`, optional)
- mapped_regions: Count of mapped regions (Linux via `/proc/*/maps` line count; macOS via `vmmap` region count, optional)
- pid_count: Number of processes included in the sample

Notes:
- Some metrics are best-effort and platform-dependent. If a metric is unavailable, the CSV column remains empty for that sample.
- Reading `/proc/*/smaps` can be slower; memmark defaults to fast mode. Use `--smaps` to enable PSS/swap collection.

## Installation

- Install using the provided `install.sh` script:
    ```sh
    curl -sL https://github.com/criccomini/memmark/raw/main/install.sh | bash
    ```
- Requirements:
  - bash ≥ 3.2 (works with the default macOS bash)
  - Standard UNIX tools: `ps`, `awk`, `grep`, `sed`, `date`
  - Linux: `/proc` available for detailed metrics
  - macOS optional: `vmmap` (ships with Xcode tools) for physical footprint and region counts
  - Optional: `gnuplot` for chart generation

## Usage

Track an existing PID:
```sh
memmark --pid 12345 --interval 1s --out run.csv --chart run.png
```

Run and track a command until it exits:
```sh
memmark --interval 500ms --out train.csv -- python train.py --epochs 3
```
On Linux, add `--smaps` to collect PSS/swap via smaps.
Stop conditions:
- If tracking a command, memmark exits when the command exits (and returns the command's exit code).
- If attaching to a PID, memmark exits when the root PID exits or when `--duration` is reached, whichever comes first.

### CLI

- `--pid <PID>`: Track an existing process. Mutually exclusive with running a command.
- `-- <COMMAND ...>`: Everything after `--` is executed and tracked as the root process.
- `--interval <DURATION>`: Sampling interval (e.g., `200ms`, `1s`, `2m`). Default: `1s`.
- `--duration <DURATION>`: Maximum duration to run. Default: run until target exits.
- `--out <PATH>`: CSV output path. Use `-` for stdout. Default: `memmark.csv` in CWD.
- `--smaps`: On Linux, parse `/proc/<pid>/smaps` to collect PSS and swap (higher overhead; disabled by default).
- `--chart <PATH>`: If set and gnuplot is available, render a PNG chart to this path.

### CSV schema

Columns (superset; some may be empty depending on OS and flags):
- `timestamp`: ISO-8601 wall time of the sample
- `unix_ms`: Unix epoch in milliseconds
- `root_pid`: The original root PID (command or attached PID)
- `pid_count`: Number of processes included in the sample
- `rss_kib`: Sum of RSS across the tree (KiB)
- `vsz_kib`: Sum of VSZ/VSIZE across the tree (KiB)
- `swap_kib`: Sum of swap usage across the tree (KiB; Linux, optional)
- `pss_kib`: Sum of PSS across the tree (KiB; Linux, optional)
- `phys_footprint_kib`: Physical footprint (macOS, optional)
- `mapped_regions`: Total mapped regions (best-effort)

Example snippet:
```csv
timestamp,unix_ms,root_pid,pid_count,rss_kib,vsz_kib,swap_kib,pss_kib,phys_footprint_kib,mapped_regions
2025-08-26T18:10:00Z,1756231800000,12345,3,81234,540000,1200,76000,,420
2025-08-26T18:10:01Z,1756231801000,12345,4,84567,541200,1300,77000,,431
```

## Charts (optional)

If `gnuplot` is installed and `--chart <png>` is provided, memmark will generate a time series chart using the CSV it produced.
- By default, it renders RSS, VSZ, and (if present) SWAP as lines.

The script embeds a minimal gnuplot program, so no extra files are required.

## How it works (high level)

- Every interval, build the descendant process set starting from the root PID.
  - Linux: `ps -e -o pid=,ppid=` and `/proc` for details
  - macOS: `ps -eo pid=,ppid=` and `ps -o` for metrics; `vmmap` optionally
- Query per-process metrics and sum across the set.
- Write one CSV row per sample.
- Optionally invoke gnuplot to render a PNG.

## Platform notes

- macOS:
  - `rss_kib` and `vsz_kib` from `ps` (KiB). `swap_kib` is typically unavailable; `vmmap -summary <pid>` may provide a physical footprint estimate (`phys_footprint_kib`).
  - Access to `vmmap` output may require proper permissions; if unavailable, memmark will omit those columns.
- Linux:
  - `rss_kib` and `vsz_kib` from `ps`. `swap_kib` and `pss_kib` parsed from `/proc/<pid>/smaps` when `--smaps` is enabled.
  - Reading `smaps` for many processes can add overhead; it is disabled by default. Use `--smaps` to enable.

## Performance & overhead

- Default interval is 1s; reduce (e.g., 200ms) for finer granularity but expect higher overhead.
- By default memmark avoids expensive smaps reads; enable `--smaps` to collect PSS/swap (higher overhead).

## Exit codes

- When running a command: memmark returns the command's exit code.
- When attaching to a PID: returns 0 on normal completion.

## Troubleshooting

- Empty `swap_kib` on macOS: expected; per-process swap is not generally available.
- Permission denied on `/proc/<pid>/smaps`: you may not have rights to inspect processes owned by other users.
- No charts produced: ensure `gnuplot` is installed and that `--chart` was provided.

## Roadmap

- Per-process breakdown mode (`--per-process` extra CSV)
- CGroup/container memory awareness (Docker, Kubernetes)
- Additional charts (stacked area for RSS/Swap)
- Homebrew formula and release tarballs

## License

MIT License.