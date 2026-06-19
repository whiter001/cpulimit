# vcpulimit

A V (vlang) port of [opsengine/cpulimit](https://github.com/opsengine/cpulimit) — limits the CPU
usage of a process by sending `SIGSTOP` / `SIGCONT` POSIX signals.

## Status

| Platform | Status |
|---|---|
| macOS   | ✅ Tested end-to-end (libproc backend) |
| Linux   | 🟡 Code complete (`/proc` parser), not yet tested on this machine |
| FreeBSD | 🟡 Code complete (kvm backend), not yet tested |

## Build

```bash
# bdw-gc headers + lib are required by V's runtime on macOS (Homebrew):
brew install bdw-gc

LDFLAGS="-L/opt/homebrew/Cellar/bdw-gc/8.2.12/lib" \
  v -enable-globals .
```

The `-enable-globals` flag is needed because the C signal handler writes to a global
flag that the main loop polls.

## Releases

Binaries for macOS (arm64 / x86_64) are published manually via the **Release** GitHub
Actions workflow. Go to *Actions → Release → Run workflow*, enter a version tag (e.g.
`v0.1.0`), and choose whether to create a draft or prerelease. Linux builds are
currently skipped.

## Usage

```
Usage: ./cpulimit [OPTIONS...] TARGET
   OPTIONS
      -l, --limit=N          percentage of cpu allowed from 0 to 100 (required)
      -v, --verbose          show control statistics
      -z, --lazy             exit if no target process, or if it dies
      -i, --include-children limit also the children processes
      -h, --help             display this help and exit
   TARGET must be exactly one of these:
      -p, --pid=N            pid of the process (implies -z)
      -e, --exe=FILE         name of the executable program file or path name
      COMMAND [ARGS]         run this command and limit it (implies -z)
```

### Examples

```bash
# Throttle an existing process by pid to 25% CPU
./cpulimit -l 25 -p 1234

# Throttle by executable name
./cpulimit -l 30 -e myworker

# Launch a fresh command and limit it
./cpulimit -l 50 -- python heavy_job.py

# Verbose: print per-cycle CPU/work/sleep stats every 10 cycles
./cpulimit -l 25 -p 1234 -v
```

## Architecture

The C version is about 700 LOC across six files. The V port keeps the same shape:

| C file | V equivalent |
|---|---|
| `cpulimit.c` (CLI + main loop) | `vcpulimit.v` |
| `process_iterator_linux.c` | inlined into `procinfo.v` under `$if linux` |
| `process_iterator_apple.c` | inlined into `procinfo.v` under `$if darwin` |
| `process_iterator_freebsd.c` | inlined into `procinfo.v` under `$if freebsd` |
| `process_iterator.c` | inlined into `procinfo.v` |
| `process_group.c` | `process_group.v` |
| `list.h` / `list.c` | dropped — V slices replace the linked-list machinery |

Platform-specific C wrappers live in `procinfo_darwin.c` / `procinfo_freebsd.c`
and their prototypes are pulled in via `procinfo_darwin.h` / `procinfo_freebsd.h`.

### Algorithm

Same as the C version:

1. Every `100ms` (`TIME_SLOT`) tick:
   - **Refresh process group.** Iterate over the target (and children if `-i`),
     hash each pid into a 1024-bucket table so we can compute
     `cpu_usage = EMA(Δcputime / Δt)`, α = 0.08.
   - **Compute target work slice.** `workingrate = min(workingrate/pcpu·limit, 1)`;
     `twork = 100ms · workingrate`.
   - **Resume.** Send `SIGCONT` to every pid in the group.
   - **Sleep `twork`.**
   - **Pause.** Send `SIGSTOP` to every pid in the group.
   - **Sleep `100ms − twork`.**
2. Exit when the group becomes empty (or in lazy mode, exit immediately).

### Differences from the C version

- **Signal handling.** C uses `signal(SIGINT, quit)` and runs cleanup in the handler.
  V's `os.signal_opt` does not run handlers in a way that can safely call back into
  V runtime code, so we use a plain `C.signal` callback that only flips a global
  flag. The main loop polls the flag between sleep slices.
- **PID lookup on macOS** uses `proc_listpids` + `proc_pidinfo(PROC_PIDTASKALLINFO)`,
  wrapped in `vcpulimit_list_pids` / `vcpulimit_read_pid` to keep the brittle
  `proc_taskallinfo` struct layout out of V code.
- **Children detection.** On Linux we walk `/proc/<pid>/stat` for each candidate
  to find ancestors. On macOS/BSD we use `ppid` directly.

## Layout

```
.
├── vcpulimit.v          # CLI parsing + main loop
├── limiter.v            # 100ms work/sleep cycle + SIGSTOP/SIGCONT
├── process_group.v      # 1024-bucket hash table + EMA CPU estimator
├── procinfo.v           # Cross-platform Process/Filter/Iterator facade
├── procinfo_darwin.c    # libproc C wrappers (macOS)
├── procinfo_darwin.h    # prototypes
├── procinfo_freebsd.c   # kvm C wrappers (FreeBSD)
├── procinfo_freebsd.h   # prototypes
├── util.v               # get_ncpu, get_pid_max, increase_priority
└── v.mod
```

## Known issues / TODO

- `os.fork` + `os.execvp` are used directly. The C version duplicates the limiter
  fork so the parent can wait and propagate the child's exit code; we do the same
  but only the first `os.wait()` return code is currently propagated.
- No support yet for `signal(SIGHUP)` reloading config — the C version doesn't
  have that either, just calling it out for completeness.
- On macOS the process lookup uses `pbi_comm` (the kernel-level short name),
  matching the C version. Path-based matching against `argv[0]` is not yet wired.
