# Phase 3: ARM64 Validation & Testing

Build, vet, test, race-test and start the application on ARM64. Everything in this phase writes to `07-build-test-results.md`, with verbatim output under `graviton-validation/raw/`.

The rule that governs this phase: **name the environment every result came from.** A pass on an x86 laptop via cross-compilation and a pass on a Graviton instance are different facts, and the exit criteria distinguish them.

## Contents

- [What each environment can prove](#what-each-environment-can-prove)
- [3.0 Build Environment Preparation](#30-build-environment-preparation)
- [3.1 Build and Vet Validation](#31-build-and-vet-validation)
- [3.2 Functional and Race Testing](#32-functional-and-race-testing)
- [3.3 Container Validation](#33-container-validation)
- [3.4 Startup Validation](#34-startup-validation)
- [Write Summary](#write-summary)

---

## What each environment can prove

| Environment | Build (pure Go) | Build (cgo) | `go vet` | `go test` | **`go test -race`** | Startup |
|---|---|---|---|---|---|---|
| x86 host, `GOARCH=arm64` cross-compile | **yes** | only with a cross-compiler | yes | no (cannot execute) | no | no |
| x86 host, native amd64 (the baseline) | n/a | n/a | yes | **yes** | **yes** (same detector) | n/a |
| x86 host, arm64 container under QEMU | yes | yes (native in-container toolchain) | yes | yes, slowly | **yes** (detection is instrumentation) | partial |
| Apple Silicon (arm64) | yes | yes | yes | **yes** | **yes** | yes (macOS, not Linux) |
| Graviton EC2 running the target OS | yes | yes | yes | **yes** | **yes** | **yes** |
| GitHub `ubuntu-24.04-arm` runner | yes | yes | yes | **yes** | **yes** | yes (Ubuntu) |
| The real target (arm64 Lambda / ECS task / EKS pod) | — | — | — | — | — | **yes, authoritative** |

Two limits to state in the report rather than work around:

**Cross-compilation executes nothing.** `GOOS=linux GOARCH=arm64 go build ./...` succeeding is a real and important result — for a pure-Go project it retires most of the build risk in one command — but it satisfies exit criterion 1 and no other. Do not let it stand in for criteria 2, 5, 8-13.

**Emulation IS acceptable for the race detector - this corrects an earlier version of this skill.** The detector is happens-before instrumentation, not a hardware probe. Measured on the same realistic bug (a lazily-warmed cache published through a plain `bool`): plain `go test` passed on both a `c7g.2xlarge` and a `c7i.2xlarge`, and `go test -race` reported **3 data races on both**. So run `-race` wherever you can run it - arm64, x86, or an emulated container - and treat a report from any of them as the same blocking defect.

What real arm64 hardware adds is two things, and only the second is about the hardware:

1. **Different scheduling and interleaving**, which can reach races x86 scheduling does not. That is a reason to run it on arm64 *as well*, not instead.
2. **The manifestation rate**, which is why a race matters more here. A message-passing litmus test with the two variables on separate cache lines observed the reader seeing the flag ahead of the data in **22.3% / 37.9% / 34.9%** of samples on `c7g.2xlarge` (80.8M / 75.5M / 87.8M samples) and **0 times in 1.2e9 samples** on `c7i.2xlarge`, identical Go 1.27.2 and 8 vCPU each. Emulation cannot reproduce that number, so a manifestation-rate claim needs real hardware; the detection does not.

If no arm64 host is available, criterion 9 still runs on x86 and still blocks on a report. What becomes `NOT RUN` is the arm64 *interleaving* coverage, not the race check itself - write it that way.

### Detect a working container runtime

Being on `PATH` is not enough; a runtime can be installed and unusable (no daemon, no VM, missing permissions). Ask each one for `info` and treat a non-answer within 20 seconds as unusable:

```bash
CONTAINER_CMD=""
for c in docker podman nerdctl finch; do
  command -v "$c" >/dev/null 2>&1 || continue
  if timeout 20 "$c" info >/dev/null 2>&1; then CONTAINER_CMD="$c"; break; fi
done
echo "CONTAINER_CMD=${CONTAINER_CMD:-none}"

# On an x86 host, confirm arm64 images actually run (binfmt/QEMU must be registered)
if [ -n "$CONTAINER_CMD" ] && [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "arm64" ]; then
  timeout 60 "$CONTAINER_CMD" run --rm --platform linux/arm64 alpine:3.20 uname -m \
    || echo "EMULATION-UNAVAILABLE: install binfmt (docker run --privileged --rm tonistiigi/binfmt --install arm64)"
fi
```

---

## 3.0 Build Environment Preparation

### Go toolchain alignment

Use the same Go minor version the deployment builds with, recorded in `01-project-assessment.md`. A different minor version changes code generation and can change test results, which then get misattributed to the architecture.

Session-scoped switching only — do not change the machine's default:

```bash
# Go's own mechanism (Go 1.21+): downloads and uses the version go.mod/toolchain names
GOTOOLCHAIN=go1.24.0 go version

# Or a specific installed toolchain, without touching PATH globally
go install golang.org/dl/go1.24.0@latest && "$(go env GOPATH)/bin/go1.24.0" download
GO="$(go env GOPATH)/bin/go1.24.0"; "$GO" version

# Or in a container pinned to the target's distribution and the right Go version
$CONTAINER_CMD run --rm --platform linux/arm64 -v "$PWD":/src -w /src golang:1.24 go version
```

Record which mechanism was used. If the toolchain used here differs from the deployment's, every result in this phase is qualified by that and must say so.

### Keep build output out of the project tree

So that `git add -A` in Phase 2's commits never picks it up:

```bash
export GOBIN="$PWD/graviton-validation/.bin"      # inside the output dir, which is committed deliberately
mkdir -p "$GOBIN"
# or, fully outside:
export GOBIN="${TMPDIR:-/tmp}/graviton-bin"; mkdir -p "$GOBIN"
```

Do not change `GOMODCACHE` or `GOCACHE` to a temporary directory unless you must: a cold module cache turns a 20-second build into a download of the whole dependency tree, and a cold build cache does the same for compilation.

### Cross-compile or build natively?

| Situation | Choose |
|---|---|
| Pure Go, and arm64 hardware is available | **native** — it also gives you test and race results |
| Pure Go, no arm64 hardware | cross-compile for criterion 1; mark 2, 5, 8-13 `NOT RUN` and say why |
| cgo, and arm64 hardware is available | **native.** Avoids per-library cross-toolchain setup entirely |
| cgo, no arm64 hardware | cross-compile with `CC=aarch64-linux-gnu-gcc` for the build check; everything else is `NOT RUN` or emulated-and-qualified |
| Container is the deployment artifact | build the image for `linux/arm64` **and** run 3.1/3.2 inside it, so the libc and library versions match production |

---

## 3.1 Build and Vet Validation

### Build, in three escalating steps

```bash
mkdir -p graviton-validation/raw

# Step 1 - cross-compile check. Cheapest, runs anywhere, proves the code is arm64-buildable.
GOOS=linux GOARCH=arm64 go build ./... \
  > graviton-validation/raw/arm64-crossbuild.log 2>&1
echo "crossbuild exit=$?" | tee -a graviton-validation/raw/arm64-crossbuild.log

# Step 2 - native build on arm64, with CGO_ENABLED as the deployment sets it.
#          This is exit criterion 2. Run it ON arm64.
CGO_ENABLED="${DEPLOY_CGO_ENABLED:-1}" go build -o "$GOBIN/" ./... \
  > graviton-validation/raw/arm64-build.log 2>&1
echo "native build exit=$?" | tee -a graviton-validation/raw/arm64-build.log

# Step 3 - the deployment's own build command (Makefile target, GoReleaser, Bazel, image build).
#          A `go build ./...` that passes while `make release` fails is not a pass.
```

Step 3 is the one that matters and the one most often skipped. `01-project-assessment.md` recorded the release build command; run that.

### Classify every failure

Every build and test failure gets exactly one label, and the label decides whether it blocks:

| Label | Means | Blocking | How to tell |
|---|---|---|---|
| `INFRA` | environment, not code: missing compiler, no network, no module proxy, missing credentials, out of disk | no | it fails the same way on the x86 baseline, or the message names a tool/credential rather than the code |
| `ARM64` | genuinely architecture-specific | **yes** | it passes on the x86 baseline and fails here |
| `PRE-EXISTING` | broken before the migration | no | it fails identically on the x86 baseline at the same commit |

The x86 baseline is not optional. Run the same command on amd64 at the same commit and keep both logs; without it, `ARM64` and `PRE-EXISTING` cannot be told apart and the report's central claim is unsupported:

```bash
GOOS=linux GOARCH=amd64 go build ./... > graviton-validation/raw/amd64-build.log 2>&1
diff <(sed 's/[0-9]\+/N/g' graviton-validation/raw/amd64-build.log) \
     <(sed 's/[0-9]\+/N/g' graviton-validation/raw/arm64-build.log) | head -40
```

### The failure messages worth recognizing

| Message | Real cause | Where it is fixed |
|---|---|---|
| `imports <pkg>: build constraints exclude all Go files in <dir>` | Shape C, reachable through an import. The chain in the message names the route | Phase 2.2 |
| `build constraints exclude all Go files in <dir>` with no import chain | Shape C in a package you named explicitly (the Pass 2 sweep) | Phase 2.2 |
| the same message, but the package's files are **all cgo files** | **not Shape C**: cgo is disabled and every file in the package is a cgo file, so nothing is left. Measured on go1.27.2: a package whose only file carries `import "C"` resolves as `CgoFiles=[main.go] Ignored=[]` with `CGO_ENABLED=1` and emits the Shape C message verbatim with `CGO_ENABLED=0` | Phase 2.1, not 2.2. Disambiguate by re-resolving that one package with `CGO_ENABLED=1 go list <dir>`: if it succeeds, this is a cgo problem |
| `gcc_arm64.S: Error: no such instruction: 'stp x29,x30,[sp,'` under `# runtime/cgo` | cgo cross-compile with **no `CC`**: the host's x86 gcc is being handed arm64 assembly from `runtime/cgo`. It reads like a Go runtime bug and is not one | set `CC=aarch64-linux-gnu-gcc`, or build natively on arm64 |
| `unrecognized instruction "MOVQ"` followed by `asm: assembly of <file>.s failed` | an unconstrained `.s` file holding x86 mnemonics, compiled for arm64 (Shape C in disguise, variant 1) | Phase 2.2 |
| `undefined: <symbol>` for a symbol defined in a `_amd64.go` file | Shape C in disguise: the generic sibling is missing a declaration | Phase 2.2 |
| `unrecognized command line option '-msse4.2'` | x86-only flag reaching the aarch64 C compiler | Phase 2.1 |
| `cannot find -lfoo` / `pkg-config: exit status 1` | the aarch64 build of a system library is not installed | Phase 2.1, Route 2 |
| `file not recognized: file format not recognized` from `ld` | an x86-64 `.a`/`.o` being linked into an arm64 binary | Phase 2.3 |
| `undefined: syscall.SYS_OPEN` | a syscall constant that does not exist on arm64 | Phase 2.5 |
| `exec format error` running a tool during the build | an x86 tool downloaded into an arm64 builder | Phase 2.3 |
| `C compiler "gcc" not found` | cgo on, no compiler in the builder image | Phase 2.1, Route 1 |
| `gcc: error: unrecognized -march value 'x86-64'` | `-march` from a Makefile or CMake reaching the arm64 compiler | Phase 2.1 |
| `/lib/ld-musl-aarch64.so.1: not found` | a glibc-linked binary in an alpine (musl) runtime image | base image mismatch, Phase 1.1's libc table |
| `-race requires cgo` / `-race is not supported` | `CGO_ENABLED=0`, or no C compiler, so the race detector cannot build | build the test binary with cgo on for the race run; see Phase 3.2 |

The first three were produced and captured against a deliberately broken fixture on go1.27.2/linux-arm64, so the strings are what the toolchain prints rather than paraphrases.

### `go vet`

```bash
go vet ./... > graviton-validation/raw/arm64-vet.log 2>&1; echo "vet exit=$?"
GOOS=linux GOARCH=amd64 go vet ./... > graviton-validation/raw/amd64-vet.log 2>&1
diff graviton-validation/raw/amd64-vet.log graviton-validation/raw/arm64-vet.log
```

Only the **difference** matters (exit criterion 5). Pre-existing vet findings are out of scope; a finding that appears only on arm64 is in scope and is usually an `unsafe`/alignment check or an assembly check (`asmdecl`) catching a real portability bug.

---

## 3.2 Functional and Race Testing

Two separate runs, two separate logs, two separate exit criteria. Do not combine them: `-race` changes timing, memory layout and build flags, so a `-race` run is not a substitute for a plain run and a plain run is not evidence for criterion 9.

### Plain test run (criterion 8)

```bash
go test ./... > graviton-validation/raw/arm64-test.log 2>&1
echo "test exit=$?" | tee -a graviton-validation/raw/arm64-test.log

# The x86 baseline at the same commit, for classification
GOARCH=amd64 go test ./... > graviton-validation/raw/amd64-test.log 2>&1
```

Compare the sets of failing packages, not the full output:

```bash
grep -E '^(FAIL|ok|---)' graviton-validation/raw/arm64-test.log | sort > /tmp/arm64.f
grep -E '^(FAIL|ok|---)' graviton-validation/raw/amd64-test.log | sort > /tmp/amd64.f
diff /tmp/amd64.f /tmp/arm64.f
```

Infrastructure failures are skipped individually and the narrowed run becomes the final build:

```bash
# Go 1.20+
go test -skip 'TestNeedsPostgres|TestNeedsS3' ./... \
  > graviton-validation/raw/arm64-test-final.log 2>&1

# Before Go 1.20, narrow with -run per package instead
```

A run that skips every test is never the final build. Record each skip and its `INFRA` evidence under CHECK Items.

### Race run (criterion 9) — mandatory, on real arm64 hardware

```bash
# Prerequisites: -race needs cgo, and therefore a C compiler. On linux/arm64 it has been
# supported since Go 1.14. If CGO_ENABLED=0, -race fails to build and that is a finding.
go env CGO_ENABLED
cc --version 2>/dev/null || gcc --version 2>/dev/null || echo "NO C COMPILER: -race cannot build"

go test -race ./... > graviton-validation/raw/arm64-race.log 2>&1
echo "race exit=$?" | tee -a graviton-validation/raw/arm64-race.log

grep -c 'WARNING: DATA RACE' graviton-validation/raw/arm64-race.log
```

For a suite whose races are timing-dependent, repetition finds more than a single pass. Do this when the suite is fast enough:

```bash
go test -race -count=5 ./... >> graviton-validation/raw/arm64-race.log 2>&1
# Or concentrate on the concurrent packages identified in Phase 1.5
go test -race -count=20 -run 'TestConcurrent|TestParallel' ./internal/... \
  >> graviton-validation/raw/arm64-race.log 2>&1
```

**A `WARNING: DATA RACE` is blocking.** Copy the full report into `07-build-test-results.md` — both goroutine stacks, the read and the write, and the creating stacks. That output is the entire fix; summarizing it loses the information. Label it `ARM64` with a `PRE-EXISTING-ROOT-CAUSE` note: the defect predates the migration, and arm64 is what turns it into an incident.

Then run the same race command on the x86 baseline and record the result. One of two things is true, and both belong in the report:

- it also races on x86 → the defect was always reachable and no one had run `-race`
- it races only on arm64 → the weak memory model is what made it observable, which is exactly this skill's thesis and worth stating as the finding it is

If the race run cannot execute at all (no arm64 hardware, no C compiler, `CGO_ENABLED=0` in a way that cannot be changed for a test build), criterion 9 is `NOT RUN`. Write it as `NOT RUN` with the reason, and carry it into `00-summary.md` under Remaining Concerns. Never record `PASS` for a check that did not run.

### Results that change without failing

These differ legitimately between architectures and are not defects. Check each and record it:

| Thing | Difference | What to do |
|---|---|---|
| float results in the last bits | arm64 fuses `x*y+z` into `FMADD`; amd64 does not | Phase 2.5's tolerance or forced rounding. Not a defect |
| map iteration order | randomized on both, by design | a test depending on it was always broken |
| goroutine scheduling order | different core count and no SMT changes interleaving | a test depending on it was always broken |
| `runtime.NumCPU()` | different vCPU-to-core mapping | a test asserting a specific count is environment-dependent |
| timer granularity / benchmark timings | different hardware | benchmarks are compared, not asserted |
| `unsafe.Sizeof` of a struct | identical on amd64 and arm64 (both LP64) | no change expected; a difference here means a 32-bit target crept in |
| `os.Getpagesize()` | 4 KB on AL2023/Ubuntu/Debian arm64, 64 KB on RHEL arm64 | graded against `01-project-assessment.md` |

### Benchmarks (optional but cheap)

Not an exit criterion — performance is the user's responsibility — but a benchmark comparison costs one command and converts "should be fine" into a number:

```bash
go test -bench . -benchmem -run '^$' -count 10 ./... > graviton-validation/raw/arm64-bench.txt 2>&1
# Same on x86 at the same commit, then:
#   go install golang.org/x/perf/cmd/benchstat@latest
#   benchstat amd64-bench.txt arm64-bench.txt
```

Report it as data, not as a conclusion: a microbenchmark delta is not a service-level delta, and the Shape B findings from Phase 1.3 (amd64 fast path with a generic fallback) are exactly where a regression legitimately shows up.

---

## 3.3 Container Validation

Only when the deployment artifact is an image.

```bash
# Build for arm64
$CONTAINER_CMD buildx build --platform linux/arm64 -t myapp:arm64-test --load . \
  > graviton-validation/raw/arm64-image-build.log 2>&1
echo "image build exit=$?"

# The image's own declared architecture
$CONTAINER_CMD image inspect myapp:arm64-test --format '{{.Architecture}} {{.Os}}'

# The BINARY's architecture, which is the one that actually matters: an arm64 image
# containing an amd64 binary passes the check above and dies with "exec format error"
$CONTAINER_CMD create --name gv-tmp myapp:arm64-test >/dev/null
$CONTAINER_CMD cp gv-tmp:/app /tmp/gv-app 2>/dev/null && file -b /tmp/gv-app
$CONTAINER_CMD rm -f gv-tmp >/dev/null; rm -f /tmp/gv-app
```

Scan **every** native file inside the image, not just the main binary. Copy the filesystem out and scan on the host, so no part of the scan runs under emulation:

```bash
$CONTAINER_CMD create --name gv-scan myapp:arm64-test >/dev/null
$CONTAINER_CMD export gv-scan > /tmp/gv-image.tar
$CONTAINER_CMD rm -f gv-scan >/dev/null

mkdir -p /tmp/gv-rootfs && tar -xf /tmp/gv-image.tar -C /tmp/gv-rootfs 2>/dev/null
find /tmp/gv-rootfs -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) 2>/dev/null \
  | while read -r f; do
      d=$(file -b "$f" 2>/dev/null)
      case "$d" in *ELF*) echo "$f: $d" ;; esac
    done | tee graviton-validation/raw/image-native-scan.txt

# Any x86-64 line in an arm64 image is a finding
grep -iE 'x86-64|80386' graviton-validation/raw/image-native-scan.txt
rm -rf /tmp/gv-rootfs /tmp/gv-image.tar
```

A `scratch` or `distroless/static` image yields exactly one ELF file. A `distroless/base` or `alpine` image yields the libc and whatever the Dockerfile installed — and that is where a downloaded x86 helper binary (`grpc_health_probe`, `dockerize`) shows up.

Then verify the multi-arch manifest, if one is published:

```bash
$CONTAINER_CMD buildx imagetools inspect myapp:multi 2>/dev/null | grep -iE 'platform|digest'
```

---

## 3.4 Startup Validation

The application must actually run. The authoritative environment is the real target (an arm64 Lambda function, an ECS task with `cpuArchitecture: ARM64`, an EKS pod on an arm64 node); a Graviton EC2 instance running the target OS is the next best.

```bash
# 1. The architecture the process reports
./app --version 2>&1 | head -5
cat > /tmp/gocheck.go <<'GO'
package main
import ("fmt";"os";"runtime")
func main() {
  fmt.Println("GOARCH =", runtime.GOARCH, "GOOS =", runtime.GOOS,
    "NumCPU =", runtime.NumCPU(), "PageSize =", os.Getpagesize(),
    "Version =", runtime.Version())
}
GO
go run /tmp/gocheck.go; rm -f /tmp/gocheck.go
# GOARCH must print arm64.

# 2. If cgo is enabled, every linked library must resolve to an aarch64 file (criterion 13)
file -b "$GOBIN/app"
ldd "$GOBIN/app" 2>/dev/null || echo "static binary (no dynamic dependencies)"
ldd "$GOBIN/app" 2>/dev/null | awk '{print $3}' | grep -v '^$' \
  | while read -r l; do echo "$l: $(file -b "$l" 2>/dev/null)"; done

# 3. Start it and watch for the architecture-specific crash signatures
timeout 30 ./app 2>&1 | tee graviton-validation/raw/arm64-startup.log
```

| Symptom | Means | Not |
|---|---|---|
| `exec format error` | wrong-architecture binary or entrypoint | a permissions problem |
| `SIGILL: illegal instruction` | x86 instruction executed on arm64, usually from an assembly path or a `GOAMD64` binary | a Go runtime bug |
| `SIGBUS: bus error` | unaligned access; arm64 is stricter than x86 for some instruction forms | memory exhaustion |
| `cannot open shared object file` | an x86 `.so` present, or a missing aarch64 library | a path problem — check `file` on it before chasing the path |
| `/lib/ld-musl-aarch64.so.1: not found` | glibc binary in an alpine image | a missing library |
| DNS resolution behaves differently | `CGO_ENABLED` changed, so `net` switched resolvers | an arm64 difference |
| a username or group resolves differently | `CGO_ENABLED` changed, so `os/user` switched implementations | an arm64 difference |
| intermittent wrong results or a hang under load | **a data race.** Go back to 3.2's race run | "needs more tuning" |

The last row is the one to internalize. An intermittent correctness problem that appears on Graviton and not on x86 is a data race until proven otherwise, and the race detector is how you prove it. Do not tune, retry or add timeouts around it.

Finally, exercise the real paths — a process that starts and serves nothing has proven very little:

```bash
# Health endpoint, one real request, and the external dependencies the service needs
curl -fsS localhost:8080/healthz && echo OK
curl -fsS localhost:8080/<a-real-endpoint> | head -5
```

---

## Write Summary

Consolidate into `00-summary.md` using the template in [documentation-standards.md](../document_references/documentation-standards.md). Three rules:

1. **Every exit criterion gets a verdict and the environment it ran in.** `PASS (Graviton c7g.xlarge, Amazon Linux 2023)` and `PASS (cross-compiled on x86)` are different facts, and criteria 2 and 8-13 cannot be satisfied by the second
2. **`NOT RUN` is a valid verdict and is not a failure.** It is a failure to write `PASS` for it
3. **Lead with the class-4 findings.** A reader skims the summary for "can I ship this"; the build either worked or it did not and that is self-evident from the criteria table, while a race report or a `CGO_ENABLED` behavior change is the thing that needs a human decision

```markdown
## Headline

<One sentence: did this module migrate, and what is the one thing a human must decide?>

Build: PASS (native, Graviton c7g.xlarge / AL2023)
Race:  1 DATA RACE in internal/cache (see 07, full detector output)  <- decide this
cgo:   none
Deps:  go.mod unchanged
```
