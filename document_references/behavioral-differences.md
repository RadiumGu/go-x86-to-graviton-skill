# Behavioral Differences — x86-64 vs linux/arm64

The evidence standard for `05-behavioral-findings.md`. Read during Phase 1.5 and whenever a behavioral verdict needs backing.

Everything in this document **compiles cleanly for arm64**. That is why it has its own file: these are the findings that survive a green build, a green test run and a successful deployment, and then produce an incident.

## Contents

- [The memory model](#the-memory-model)
- [Floating point: FMA fusion](#floating-point-fma-fusion)
- [Syscall numbers and seccomp](#syscall-numbers-and-seccomp)
- [Page size](#page-size)
- [CPU feature dispatch](#cpu-feature-dispatch)
- [cgo-dependent net and os/user](#cgo-dependent-net-and-osuser)
- [Core count, SMT and concurrency assumptions](#core-count-smt-and-concurrency-assumptions)
- [Things that are the same and are often claimed otherwise](#things-that-are-the-same-and-are-often-claimed-otherwise)
- [False verdicts](#false-verdicts)

---

## The memory model

### What differs

x86-64 implements Total Store Order (TSO): stores become visible to other cores in program order, and the only reordering a program can observe is a store buffered ahead of a later load. AArch64 is **weakly ordered**: stores and loads can become visible out of program order, and a core can observe another core's writes in an order that core did not write them.

### What this means for Go

The Go memory model is defined by the language, not by the hardware, and it is **architecture-independent for programs without data races**. A correctly synchronized Go program — one where every concurrent access to shared state is ordered by a channel, a mutex, `sync/atomic`, `sync.Once`, `sync.WaitGroup` or another documented happens-before edge — behaves identically on amd64 and arm64. The compiler emits whatever barriers each architecture needs.

A Go program **with** a data race has undefined behavior on both architectures. The difference is empirical, not semantic: on x86's TSO the window in which a race produces a wrong value is often vanishingly small, while on arm64 it is wide enough to hit in production.

So the accurate statement is not "arm64 breaks racy code". It is:

> **arm64 reveals races that x86 hides.** The defect was always there. The migration is when you find out.

This framing matters operationally. A team that believes Graviton broke their service rolls back. A team that understands Graviton exposed a two-year-old race fixes the race.

### How to find it

There is no static pattern. The check is the race detector, on real arm64 hardware:

```bash
go test -race ./... 2>&1 | tee graviton-validation/raw/arm64-race.log
grep -c 'WARNING: DATA RACE' graviton-validation/raw/arm64-race.log
```

Repetition finds timing-dependent races a single pass misses:

```bash
go test -race -count=10 ./... 2>&1 | tee -a graviton-validation/raw/arm64-race.log
go test -race -count=50 -run 'TestConcurrent|TestParallel|TestRace' ./internal/... 2>&1 \
  | tee -a graviton-validation/raw/arm64-race.log
```

Requirements and limits:

- `-race` needs cgo and therefore a C compiler. On `linux/arm64` the race detector has been supported since Go 1.14
- `CGO_ENABLED=0` means `-race` will not build. If the deployment sets `CGO_ENABLED=0`, build the **test** binary with cgo on for this check specifically and note it
- **the race detector only reports races it observes.** A clean run is evidence, not proof. Say "no race observed in N runs of the suite", not "race-free"
- **emulation is not evidence.** QEMU's user-mode emulation does not faithfully reproduce arm64's memory ordering. A clean `-race` run inside an emulated arm64 container on an x86 host does not satisfy exit criterion 9

### Raising the prior

Phase 1.5 records what makes a race more likely, so Phase 3 knows where to aim:

```bash
grep -rn --include='*.go' -c '\bgo func\b' . --exclude-dir=vendor 2>/dev/null | awk -F: '$2>0'
grep -rn --include='*.go' -E 'sync/atomic|atomic\.(Load|Store|Add|Swap|Compare)' . --exclude-dir=vendor 2>/dev/null
grep -rn --include='*.go' -E 'map\[[^]]+\][^=]*$' . --exclude-dir=vendor 2>/dev/null | head   # shared maps
grep -rn -E '//[[:space:]]*nolint.*race|//[[:space:]]*(TODO|FIXME|XXX|HACK).*(race|lock|sync)' . \
  --include='*.go' --exclude-dir=vendor 2>/dev/null

# Does CI ever run -race? A "no" here is the finding.
grep -rn 'go test' . --include='Makefile' --include='*.mk' --include='*.sh' \
  --include='*.yml' --include='*.yaml' --exclude-dir=.git 2>/dev/null | grep -c -- '-race'
```

A project whose CI has never run `-race` is carrying an unmeasured risk into the migration. State that plainly in the report; it changes how much weight exit criterion 9 deserves.

### Fixing

```go
// Unsynchronized counter: wrong on both architectures, observably wrong on arm64
type stats struct{ hits int64 }
func (s *stats) hit()         { s.hits++ }
func (s *stats) read() int64  { return s.hits }

// Fixed (Go 1.19+)
type stats struct{ hits atomic.Int64 }
func (s *stats) hit()        { s.hits.Add(1) }
func (s *stats) read() int64 { return s.hits.Load() }
```

```go
// Unsynchronized map: the classic one, and the one that corrupts rather than miscounts
type cache struct{ m map[string]entry }

// Fixed
type cache struct {
    mu sync.RWMutex
    m  map[string]entry
}
func (c *cache) get(k string) (entry, bool) {
    c.mu.RLock(); defer c.mu.RUnlock()
    e, ok := c.m[k]; return e, ok
}
```

**Non-fixes.** Each of these makes the race harder to observe and leaves it in the program, which is worse than before because someone now believes it was fixed:

- `time.Sleep` anywhere near the race
- `runtime.Gosched()`
- changing a channel's buffer size
- reordering statements
- `GOMAXPROCS=1`
- `GOGC` or `GOMEMLIMIT` tuning
- adding a retry around the symptom
- `//nolint` on the detector's report

If the correct fix requires redesigning ownership of a shared structure and that is beyond this transformation, it is a user decision: full detector output in the report, exit criterion 9 not passing, and no change applied.

---

## Floating point: FMA fusion

### What differs

The Go specification permits an implementation to fuse floating-point operations:

> "An implementation may combine multiple floating-point operations into a single fused operation, possibly across statements, and produce a result that differs from the value obtained by executing and rounding the instructions individually. An explicit floating-point type conversion rounds to the precision of the target type, preventing fusion that would discard that rounding."

Go's arm64 backend emits `FMADD` for `x*y + z`; the amd64 backend does not fuse. So the same expression in the same program can produce results that differ in the last bits between the two architectures — **correctly, per the specification, on both**.

The fused result is usually the *more* accurate one: it rounds once instead of twice.

### Where it surfaces

Almost always in a test that asserts exact float equality against a value recorded from an amd64 run:

```bash
grep -rn --include='*_test.go' -E '(==|!=)[[:space:]]*-?[0-9]+\.[0-9]' . --exclude-dir=vendor 2>/dev/null
grep -rn --include='*_test.go' -E '(Equal|Equalf)\([^)]*-?[0-9]+\.[0-9]{6,}' . --exclude-dir=vendor 2>/dev/null
```

Also, less often but more seriously, in code where a float result is persisted, hashed, or compared across machines: a checksum over float values, a reproducible-build guarantee, a cross-service consistency check, a golden-file comparison.

### Fixing

```go
// Option 1 - force the rounding. An explicit conversion rounds to the target type,
// which prevents the fusion. Use when bit-identical cross-architecture output is required.
acc += float64((x - mean) * (x - mean))

// Option 2 - compare with a tolerance. Preferred for tests; it was the right assertion anyway.
const eps = 1e-12
if math.Abs(got-want) > eps {
    t.Fatalf("got %v, want %v (±%v)", got, want, eps)
}

// Option 3 - accept the arm64 value and update the expectation, recording why.
// Valid only when nothing downstream compares results across architectures.
```

Option 1 costs both the FMA's accuracy and its speed on arm64. Option 2 is the right default for tests. There is **no supported compiler flag or `GOEXPERIMENT` to disable fusion**; do not go looking for one.

### Not affected

Integer arithmetic, `math/big`, `encoding/binary`, and decimal libraries (`shopspring/decimal`, `cockroachdb/apd`) are exact on both architectures. Financial code using integer cents or a decimal type has no exposure here — which is worth stating, because "floating point differs on ARM" gets over-generalized into a payments-code panic.

---

## Syscall numbers and seccomp

### What differs

Linux syscall numbers are per-architecture. Several syscalls that exist on x86-64 have **no arm64 number at all**, because arm64 was defined later and dropped the legacy forms:

| x86-64 syscall | arm64 equivalent |
|---|---|
| `open` | `openat` |
| `fork` | `clone` |
| `pipe` | `pipe2` |
| `dup2` | `dup3` |
| `poll` | `ppoll` |
| `epoll_create` | `epoll_create1` |
| `inotify_init` | `inotify_init1` |
| `rename`, `unlink`, `mkdir`, `rmdir`, `symlink`, `link`, `chmod`, `chown` | the `*at` forms |
| `getdents` | `getdents64` |

And the numbers that do exist differ: on x86-64, `186` is `gettid`; on arm64, `gettid` is `178` and `186` is `msgget`.

### The loud case

A Go program referencing `syscall.SYS_OPEN` fails to **compile** for arm64 — the constant does not exist in `syscall` for that architecture. This is the good outcome: a compile error names the file and line.

```bash
grep -rn --include='*.go' -E 'syscall\.SYS_|unix\.SYS_|syscall\.(Syscall|RawSyscall)\(' . \
  --exclude-dir=vendor 2>/dev/null
```

Fix by using the portable call:

```go
// Before
fd, _, errno := syscall.Syscall(syscall.SYS_OPEN, uintptr(unsafe.Pointer(p)), 0, 0)

// After - x/sys/unix, which resolves the right number per architecture
fd, err := unix.Openat(unix.AT_FDCWD, path, unix.O_RDONLY, 0)

// Or, usually, just
f, err := os.Open(path)
```

### The silent case

A **numeric** seccomp or BPF filter. The numbers are baked in, the architecture changes, and nothing errors:

```bash
grep -rn -iE 'seccomp|SCMP_|BPF_|AUDIT_ARCH|libseccomp' . \
  --include='*.go' --include='*.json' --include='*.yaml' --include='*.yml' \
  --exclude-dir=.git --exclude-dir=vendor 2>/dev/null
```

| Filter form | Portable? | On arm64 |
|---|---|---|
| Docker/containerd JSON profile using syscall **names** | yes | the runtime resolves names per architecture. Fine |
| `libseccomp` rules using `unix.SYS_*` constants | yes | the constant resolves per architecture. Fine |
| Hand-written BPF with literal syscall numbers | **no** | permits and denies the wrong calls, silently |
| A profile with an `architectures: [SCMP_ARCH_X86_64]` list and no arm64 entry | **no** | the filter does not apply at all — fails *open* |
| A filter pinned to `AUDIT_ARCH_X86_64` | **no** | fails open or closed depending on the library |

This is a security finding, not just a portability one, and the report must say which direction it fails. A filter that stops applying is a silent loss of containment; one that fails closed is an outage. Both need naming.

```json
// Docker seccomp profile: the architectures list needs the arm64 entries
{
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32",
                    "SCMP_ARCH_AARCH64", "SCMP_ARCH_ARM"],
  "syscalls": [{ "names": ["openat", "read", "write"], "action": "SCMP_ACT_ALLOW" }]
}
```

---

## Page size

### What differs

x86-64 Linux always uses 4 KB pages. arm64 kernels can be built for 4 KB, 16 KB or 64 KB, and distributions differ:

| arm64 distribution | Page size |
|---|---|
| Amazon Linux 2023 | 4 KB |
| Ubuntu (all supported) | 4 KB |
| Debian | 4 KB |
| RHEL / CentOS Stream / Rocky / Alma | **64 KB** |
| SLES | 64 KB |

So on the common AWS path — Amazon Linux, Ubuntu, Debian — a hardcoded `4096` is latent rather than broken. On a RHEL-family arm64 target it is a blocker.

**Grade the finding against the target recorded in Phase 1.1**, rather than reporting it as a uniform arm64 risk:

```bash
# On the target, or inside the target's image
getconf PAGESIZE
```

### Finding it

```bash
grep -rn --include='*.go' -E '\b4096\b' . --exclude-dir=vendor 2>/dev/null
grep -rn --include='*.go' -E 'Getpagesize|PageSize|mmap|Mmap|Mprotect|Madvise|MAP_[A-Z]' . \
  --exclude-dir=vendor 2>/dev/null
```

Then separate the hits that matter. Only uses that interact with page-granular operations are findings:

| `4096` used as | Finding? |
|---|---|
| `mmap`/`mprotect`/`madvise` length or alignment | **yes** |
| a page-alignment mask (`addr & ^uintptr(4095)`) | **yes** |
| a hugepage or memory-arena calculation | **yes** |
| an I/O buffer size | no |
| a disk block size, a protocol frame size, a max key length | no |
| a `bufio` size hint | no |

```go
// Before
const pageSize = 4096
off := addr & ^uintptr(pageSize-1)

// After
pageSize := os.Getpagesize()
off := addr & ^uintptr(pageSize-1)
```

Note that `os.Getpagesize()` is a run-time value, so it cannot be a `const`. Code that needs a compile-time array size keyed on the page size needs restructuring, which may exceed this transformation's scope.

---

## CPU feature dispatch

Covered in detail in [build-constraints-and-assembly.md](build-constraints-and-assembly.md#xsyscpu-feature-bits-on-graviton). The behavioral point here is narrow:

**The finding is never the `if`. It is the final `else`.**

```go
// Finding: on Graviton this returns an error for every call
if cpu.X86.HasAVX2 { return fastPath(xs) }
return nil, errors.New("CPU not supported")

// Fixed
switch {
case cpu.X86.HasAVX2:      return fastPath(xs), nil
case cpu.ARM64.HasASIMD:   return neonPath(xs), nil
default:                   return genericPath(xs), nil
}
```

Where no arm64 implementation exists, `default` calls a correct generic path. Returning an error, panicking, or silently disabling a feature are all findings — and the first two are at least loud, while the third is the dangerous one.

```bash
# The shape to hunt: a file reading x86 bits with no arm64 bit anywhere in it
grep -rl --include='*.go' 'cpu\.X86\.' . --exclude-dir=vendor 2>/dev/null \
  | while read -r f; do grep -q 'cpu\.ARM64\.' "$f" || echo "X86-ONLY DISPATCH: $f"; done
```

---

## cgo-dependent `net` and `os/user`

### What differs

This is **not** an architecture difference. It is a `CGO_ENABLED` difference that this transformation can introduce by accident, which makes it one of the most commonly misattributed findings in a Graviton migration.

| | `CGO_ENABLED=1` + C toolchain | `CGO_ENABLED=0`, or `-tags netgo,osusergo` |
|---|---|---|
| DNS resolution | may call libc `getaddrinfo`: honors `/etc/nsswitch.conf`, NSS modules (LDAP, SSSD, mDNS, systemd-resolved behavior), and libc's own search and timeout rules | Go's own resolver: parses `/etc/resolv.conf` directly, **ignores NSS entirely** |
| User and group lookup | may call libc `getpwnam`/`getgrnam`: honors NSS | reads `/etc/passwd` and `/etc/group` directly |
| `go test -race` | available | **does not build** |
| Linking | dynamic by default | static by default |

Go chooses between the two resolvers at run time based on the configuration it finds, so the cgo-enabled case is "may use" rather than "always uses" — but the pure-Go case can never use NSS at all.

### Why it shows up here

A cgo link error is the most common arm64 build blocker, and `CGO_ENABLED=0` makes it vanish in one character. If the deployment runs with cgo enabled and the migration turns it off, the service's name resolution changes — and in an environment using LDAP or SSSD through NSS, or relying on libc's search-domain handling, it changes in a way that produces intermittent resolution failures days later.

```bash
# Record the current value from every place it is set
grep -rn -E 'CGO_ENABLED|netgo|osusergo' . \
  --include='Makefile' --include='*.mk' --include='*.sh' --include='Dockerfile*' \
  --include='*.yml' --include='*.yaml' --exclude-dir=.git 2>/dev/null
go env CGO_ENABLED
```

If this transformation changes it in either direction, that is a documented behavior change requiring user confirmation — never a build fix. The text to use is in Phase 2.5.

A related and legitimate case: a **static** cgo binary for a `scratch`/`distroless-static` image must use `-tags netgo osusergo`, because glibc's NSS loads shared objects at run time and a static binary cannot. That is not optional, and the behavior change comes with it.

---

## Core count, SMT and concurrency assumptions

### What differs

Every Graviton vCPU is a physical core. There is no simultaneous multithreading ([AWS Graviton performance testing](https://docs.aws.amazon.com/whitepapers/latest/aws-graviton-performance-testing/other-considerations.html)). On x86 instance families, two vCPUs share one physical core.

So an 8-vCPU Graviton instance has **8 physical cores**; an 8-vCPU x86 instance has **4**. `runtime.NumCPU()` returns 8 on both, and `GOMAXPROCS` defaults to it on both — correctly, in both cases.

### What this means

Nothing fails. But several numbers calibrated on x86 are now describing a different machine:

- throughput per vCPU usually improves, and scales more linearly with load because there is no hyperthread contention
- an autoscaling threshold tuned to "scale out at 60% CPU" was tuned against a curve that bent earlier than this one does
- a worker-pool size derived from `NumCPU()/2` (a common "physical cores" heuristic) now under-provisions by half
- a benchmark comparison at low load understates the Graviton advantage, because the x86 instance has not yet hit hyperthread contention

```bash
grep -rn --include='*.go' -E 'NumCPU\(\)|GOMAXPROCS' . --exclude-dir=vendor 2>/dev/null
grep -rn -E 'GOMAXPROCS|automaxprocs' . --include='*.yml' --include='*.yaml' \
  --include='Dockerfile*' --include='Makefile' --exclude-dir=.git 2>/dev/null
```

A `NumCPU()/2` heuristic is a finding worth reporting — not a code change in scope, but a line in `06-runtime-configuration.md` explaining that the heuristic's premise does not hold on Graviton.

### The container case, which is not architecture-specific but is always discovered here

`runtime.NumCPU()` reports the host's cores, not the cgroup CPU quota. A Go process in a container limited to 2 CPUs on a 64-core host gets `GOMAXPROCS=64`, which causes excessive context switching and GC worker oversubscription. This is true on x86 too — it just becomes more visible when the instance size changes. The fix is `go.uber.org/automaxprocs` or an explicit `GOMAXPROCS`, and it belongs in `06-runtime-configuration.md` as Level A.

---

## Things that are the same and are often claimed otherwise

Stating these explicitly prevents phantom findings:

| Claim | Reality |
|---|---|
| "ARM is big-endian, so byte-order bugs will surface" | **AArch64 on Linux is little-endian**, like x86-64. A big-endian port is `s390x` or `ppc64`, not this one. This is a decades-stale fact and the most common wrong claim in Graviton write-ups |
| "`int` is 32-bit on ARM" | `linux/arm64` is LP64: `int` is 64-bit, as on amd64. 32-bit ARM (`GOARCH=arm`) is a different port |
| "struct layouts differ, so `unsafe` code breaks" | `unsafe.Sizeof`, `Alignof` and `Offsetof` are identical on amd64 and arm64 |
| "64-bit atomics need manual alignment on ARM" | that is a 32-bit (`GOARCH=arm`, `386`) requirement. On arm64, 64-bit values are naturally aligned |
| "Goroutine scheduling differs" | the scheduler is architecture-independent. Core count differs, which changes *interleaving*, not semantics — and a test depending on interleaving was always broken |
| "The GC behaves differently" | architecture-independent. Memory bandwidth and cache sizes differ, which is performance, not behavior |
| "Map iteration order differs" | randomized on both by design |
| "`time` resolution differs" | the monotonic clock source differs in hardware; `time.Now()` semantics do not. A benchmark number differs; a timeout does not change meaning |
| "stdlib packages need arm64-specific handling" | `net/http`, `encoding/json`, `database/sql`, `crypto/*` are portable. A stdlib package is never the arm64 finding |
| "Go code must be recompiled with special flags for ARM" | `GOARCH=arm64` is the whole requirement. `GOARM64` is an optional microarchitecture level, Level B, and never required |

---

## False verdicts

| False verdict | Why it is wrong | The real check |
|---|---|---|
| "No races found, the code is race-free" | the detector reports only what it observes | "no race observed in N runs of the suite" |
| "`-race` passed in the arm64 container" (on an x86 host) | QEMU does not reproduce arm64 memory ordering | real arm64 hardware, or `NOT RUN` |
| "arm64 introduced a data race" | the race predates the migration | `-race` on the x86 baseline at the same commit, reported alongside |
| "Float results changed, so arm64 is less accurate" | the FMA-fused result rounds once instead of twice and is usually more accurate | state the mechanism, not a quality judgement |
| "All float code is at risk" | integer, `math/big` and decimal arithmetic are exact on both | identify fusible `x*y+z` shapes specifically |
| "A hardcoded 4096 is a blocker" | on AL2023/Ubuntu/Debian arm64 the page size is 4 KB | `getconf PAGESIZE` on the target, and check what the constant is used for |
| "The seccomp profile uses names, but it is pinned to x86" | the `architectures` list is a separate thing from the syscall names | read both the names and the architectures list |
| "DNS broke on arm64" | `CGO_ENABLED` changed during the migration | compare the `CGO_ENABLED` the deployment uses, before and after |
| "`GOMAXPROCS` needs changing for Graviton" | the default is correct on both; the *instance sizing* assumptions are what changed | report it as a sizing recommendation, Level A, not a code change |
| "An intermittent wrong result needs more tuning" | it is a data race until proven otherwise | `go test -race -count=N` on the suspect packages |
