# Phase 2: Compatibility Resolution

Apply fixes for ARM64-blocking issues **only**. Every change in this phase traces back to a named finding in a Phase 1 report. A change with no Phase 1 finding behind it is out of scope; delete it.

Commit after each sub-step that changed files, with the step number in the message.

## Contents

- [2.1 cgo Resolution](#21-cgo-resolution)
- [2.2 Build Constraint and Assembly Resolution](#22-build-constraint-and-assembly-resolution)
- [2.3 Native Artifact Resolution](#23-native-artifact-resolution)
- [2.4 Build Configuration Updates](#24-build-configuration-updates)
- [2.5 Behavioral Fixes](#25-behavioral-fixes)
- [2.6 Graviton Runtime Recommendations](#26-graviton-runtime-recommendations)

---

## 2.1 cgo Resolution

Resolves `BLOCKER` and `NEEDS AARCH64 BUILD` items from `02-cgo-report.md`.

### Make `#cgo` directives per-architecture

A `#cgo` directive accepts the same constraint vocabulary as `//go:build`. Split rather than delete, so the x86 build keeps its optimization:

```go
// Before - fails on arm64 with: unrecognized command line option '-msse4.2'
/*
#cgo CFLAGS: -O3 -msse4.2 -maes
#cgo LDFLAGS: -lcrypto
#include "hash.h"
*/
import "C"
```

```go
// After - each architecture gets flags its compiler accepts
/*
#cgo CFLAGS: -O3
#cgo amd64 CFLAGS: -msse4.2 -maes
#cgo arm64 CFLAGS: -march=armv8-a+crypto
#cgo LDFLAGS: -lcrypto
#include "hash.h"
*/
import "C"
```

`-march=armv8-a+crypto` is safe on every Graviton generation (Graviton2 is Neoverse N1 / ARMv8.2-A). Do not reach for a higher baseline than the oldest instance family the fleet runs; `01-project-assessment.md` records which that is.

For the environment form, make it conditional in the same way:

```make
# Makefile - before
CGO_CFLAGS = -O3 -msse4.2

# Makefile - after
GOHOSTARCH := $(shell go env GOARCH)
CGO_CFLAGS  = -O3
ifeq ($(GOHOSTARCH),amd64)
CGO_CFLAGS += -msse4.2
endif
ifeq ($(GOHOSTARCH),arm64)
CGO_CFLAGS += -march=armv8-a+crypto
endif
```

### Resolve each C library by its route

The four routes from Phase 1.2 take four different fixes. The method and evidence standard for each is in [cgo-and-native-dependencies.md](../document_references/cgo-and-native-dependencies.md).

**Route 1 — vendored C source.** Nothing to port. Confirm a C compiler is present in the arm64 build environment and move on:

```bash
# In the arm64 builder image
cc --version || gcc --version
```

If the Dockerfile's builder stage is `golang:1.x-alpine`, it has no C compiler by default; add `build-base` (alpine) or `build-essential` (debian). This is a build-environment fix, not a code fix.

**Route 2 — system library via `-lfoo` or `pkg-config`.** Install the aarch64 package in the arm64 build and runtime environments. The package name usually does not change; the architecture of the repository does:

```dockerfile
# Builder stage, arm64: the same package names, from the arm64 repositories
RUN apt-get update && apt-get install -y --no-install-recommends \
      libzstd-dev libsnappy-dev pkg-config && rm -rf /var/lib/apt/lists/*
```

Verify availability before editing, so a missing package is found now rather than in Phase 3:

```bash
# Debian/Ubuntu arm64 index, queried from an x86 host without emulation
docker run --rm --platform linux/amd64 ubuntu:24.04 sh -c '
  dpkg --add-architecture arm64 2>/dev/null
  sed -i "s|^deb |deb [arch=amd64] |" /etc/apt/sources.list.d/*.sources 2>/dev/null || true
  echo "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports noble main universe" \
    > /etc/apt/sources.list.d/arm64.list
  apt-get update -qq 2>/dev/null
  apt-cache policy libzstd-dev:arm64'

# Amazon Linux 2023 aarch64
docker run --rm amazonlinux:2023 sh -c \
  'dnf -q --forcearch=aarch64 list available libzstd-devel 2>&1 | tail -5'
```

On an amd64 Ubuntu image the default mirrors carry no arm64 files (`apt-get update` reports `binary-arm64/Packages 404 Not Found`): keep the image's own sources for amd64 and read arm64 from `ports.ubuntu.com`, as above. Bound each index download with `timeout 300`.

**Route 3 — bundled prebuilt archive.** The fix is a version change, and it is the one dependency update this skill endorses, because the arm64 archive's existence is a property of the exact version. Find the lowest version whose bundle includes an arm64 archive, and cite the archive file name as the evidence:

```bash
# Example shape: confirm the arm64 static library is actually inside the module version
mod=github.com/confluentinc/confluent-kafka-go/v2
ver=v2.3.0
GOFLAGS=-mod=mod go mod download -x "$mod@$ver" 2>/dev/null
find "$(go env GOMODCACHE)/$mod@$ver" -name '*.a' 2>/dev/null | sed 's|.*/||' | sort
# A line naming arm64 (e.g. librdkafka_glibc_linux_arm64.a) is the evidence. Its absence is the finding.
```

Record the upgrade in `02-cgo-report.md` as `ARM64-REQUIRED` with the archive name quoted. Then apply it through the module system, never by hand-editing `go.mod`:

```bash
go get "$mod@$ver"
go mod tidy
[ -d vendor ] && go mod vendor      # a vendored project MUST re-vendor, or the old archive still ships
git add -A && git commit -m "2.2 deps: $mod -> $ver for bundled linux/arm64 archive"
```

Many such modules also offer a dynamic-linking build tag as an alternative to the bundle (`-tags dynamic` for `confluent-kafka-go`), which trades the bundled archive for a system library and so converts Route 3 into Route 2. Offer both; the choice is the user's, because it changes their deployment image.

**Route 4 — library downloaded at build time.** Covered in 2.3.

**BLOCKER with no aarch64 build at all.** Do not substitute a library on your own authority. Write the finding as a user decision with three concrete options and their costs:

```markdown
## User Decision Required: <library>

**Finding:** `<pkg>` links `<library>` via cgo. No aarch64 build exists
(<evidence: upstream issue, release matrix, or the vendor's platform list>).

**Options**
1. Substitute `<pure-Go or ported alternative>` — <behavioral differences, API surface delta>
2. Drop the feature on arm64 behind a build tag — <what users lose>
3. Keep this service on x86 and migrate the rest — <no code change; the fleet is mixed>

**Not recommended:** emulating x86 on Graviton. It removes the price-performance
reason for the migration and adds a failure mode.
```

---

## 2.2 Build Constraint and Assembly Resolution

Resolves Shape C findings from `03-build-constraint-report.md`. Shape A needs nothing. Shape B needs nothing — leaving an amd64 fast path in place with a working generic fallback is the correct outcome, not a defect.

### Three fixes, in order of preference

**Fix 1 — relax the gate (preferred when the code is portable).** Most Shape C files are gated on `amd64` because that was the only architecture anyone built, not because the code is x86-specific. If the file contains no assembly, no intrinsics and no x86-only syscall, widen the constraint:

```go
// Before
//go:build amd64

// After - the code was never x86-specific; it was only ever built there
//go:build amd64 || arm64
```

Confirm, do not assume, that the body is portable:

```bash
f=internal/fast/impl_amd64.go
grep -nE 'cpu\.X86|asm|unsafe\.|syscall\.SYS_|0x[0-9a-fA-F]{8,}' "$f"
```

If the file name carries the suffix (`impl_amd64.go`), the suffix overrides a widened `//go:build` line — rename the file as part of the fix:

```bash
git mv internal/fast/impl_amd64.go internal/fast/impl_asm.go
# then add //go:build amd64 || arm64 inside it
```

**Fix 2 — add a generic Go implementation.** When the amd64 file genuinely is x86-specific (assembly, intrinsics), add a portable sibling rather than touching the fast path:

```go
// internal/hash/hash_amd64.go   (unchanged)
//go:build amd64

// internal/hash/hash_generic.go  (new)
//go:build !amd64

package hash

// Sum is the portable implementation. It must be functionally identical to the
// amd64 path; hash_test.go runs the same vectors against both.
func Sum(b []byte) uint64 { /* ... */ }
```

The test file must not itself be architecture-gated, or the new path ships untested:

```bash
# A test file with an amd64 constraint leaves the generic path unverified - a silent Shape B
grep -lE '^//[[:space:]]*(go:build|\+build)[^\n]*amd64' internal/hash/*_test.go
```

**Fix 3 — add an arm64 implementation.** Only when a measured requirement justifies it, and only with upstream prior art to work from. Hand-written arm64 assembly is correct or the tests fail; it is not reviewable by inspection. If the package is a dependency rather than project code, the right move is upstream: check whether an arm64 port already exists in a newer version before writing one.

### When the Shape C file is in `vendor/` or a dependency

Do not patch `vendor/`. A hand-edited vendor tree is silently reverted by the next `go mod vendor`, and the fix disappears from the build with no error.

In order of preference:

1. **Upgrade the dependency.** Check whether a newer version has the arm64 path — for most widely-used modules it does, and this is the single most common real fix:
   ```bash
   go list -m -versions github.com/example/dep
   # then, for a candidate version, confirm the arm64 file exists
   GOFLAGS=-mod=mod go mod download github.com/example/dep@v1.9.0
   find "$(go env GOMODCACHE)/github.com/example/dep@v1.9.0" -name '*arm64*' | head
   ```
   Record it in `03-build-constraint-report.md` as `ARM64-REQUIRED` and name the file you found.
2. **A `replace` directive to a fork that has the arm64 path.** A user decision: it changes who maintains that code.
3. **A pure-Go build tag the dependency already offers** (`purego`, `noasm`, `appengine` on older modules):
   ```bash
   grep -rn -E '^//[[:space:]]*(go:build|\+build)[^\n]*(purego|noasm)' "$(go env GOMODCACHE)/github.com/example/dep@v1.8.0" | head
   go build -tags purego ./...
   ```
   Adding a build tag changes every architecture's build, including x86, so the performance effect is global. Document it; do not apply it silently.

After any dependency change:

```bash
go mod tidy
[ -d vendor ] && go mod vendor
GOOS=linux GOARCH=arm64 go build ./... 2>&1 | tail -20
# Re-run the Phase 1.1 capture and the 1.3 scan; the constraint landscape has changed
GOOS=linux GOARCH=arm64 go list -deps -json ./... \
  > graviton-validation/raw/go-list-deps-arm64.json 2>graviton-validation/raw/go-list-deps-arm64.err
```

**Re-running Phase 1 after a dependency change is mandatory**, not optional. One upgrade pulls a new transitive set, which can introduce a constraint problem that was not there before. The Phase 1 reports must describe the tree as it stands at the end of Phase 2.

---

## 2.3 Native Artifact Resolution

Resolves findings from `04-artifact-and-build-config-findings.md`.

### Committed binaries

Replace with the aarch64 build from the same upstream source and version — never a different version, which mixes an architecture change with a functional one. Verify by content after replacing:

```bash
file -b third_party/libfoo/linux_arm64/libfoo.a
ar p third_party/libfoo/linux_arm64/libfoo.a "$(ar t third_party/libfoo/linux_arm64/libfoo.a | head -1)" \
  > /tmp/m.o && file -b /tmp/m.o && rm -f /tmp/m.o
```

Keep the x86 artifact. Lay the tree out per architecture and select with a build constraint, so one tree serves both:

```
third_party/libfoo/
├── linux_amd64/libfoo.a
└── linux_arm64/libfoo.a
```

```go
// libfoo_amd64.go
//go:build amd64
/*
#cgo LDFLAGS: -L${SRCDIR}/third_party/libfoo/linux_amd64 -lfoo
*/
import "C"

// libfoo_arm64.go
//go:build arm64
/*
#cgo LDFLAGS: -L${SRCDIR}/third_party/libfoo/linux_arm64 -lfoo
*/
import "C"
```

`${SRCDIR}` is expanded by cgo to the package directory, so this works regardless of where the build runs. A relative `-L./third_party/...` does not.

### Downloaded binaries

Make the URL derive the architecture rather than naming one. In a Dockerfile, use the build argument Docker already provides:

```dockerfile
# Before - produces an x86 binary inside an arm64 image: "exec format error" at run time
ADD https://github.com/grpc-ecosystem/grpc-health-probe/releases/download/v0.4.26/grpc_health_probe-linux-amd64 /bin/grpc_health_probe

# After
ARG TARGETARCH
ADD https://github.com/grpc-ecosystem/grpc-health-probe/releases/download/v0.4.26/grpc_health_probe-linux-${TARGETARCH} /bin/grpc_health_probe
RUN chmod +x /bin/grpc_health_probe
```

`TARGETARCH` is `amd64` or `arm64` — the same vocabulary Go uses, so no mapping is needed. In a shell script outside Docker, map from `uname -m`, which uses different names:

```bash
# uname -m says x86_64 / aarch64; releases are usually named amd64 / arm64
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
curl -fsSL "https://example.com/tool-linux-${ARCH}.tar.gz" | tar xz -C /usr/local/bin
```

The explicit failure branch matters. A `case` that silently falls through to `amd64` is how an x86 binary gets into an arm64 image.

Prefer `go install` for Go-written tools, which needs no URL and no architecture logic at all:

```dockerfile
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.6
```

### Image references

```dockerfile
# Before
FROM --platform=linux/amd64 alpine:3.20

# After - let the build's platform drive it
FROM alpine:3.20
```

For a registry image with no arm64 manifest, the options in order: a newer tag that is multi-arch; the upstream's own arm64-tagged variant; an equivalent image from a different publisher (a user decision, it changes the supply chain); or build it yourself. Record the choice and its evidence line from `raw/image-platforms.txt`.

---

## 2.4 Build Configuration Updates

### Dockerfile: the cross-compiling multi-stage pattern

This is the single highest-value change in the whole phase, and it is a Go-specific advantage: **because Go cross-compiles, the builder stage should run on the native build machine and cross-compile for the target** — no emulation, no QEMU, full build speed, for both architectures.

```dockerfile
# syntax=docker/dockerfile:1

# Builder runs NATIVELY on whatever the build machine is...
FROM --platform=$BUILDPLATFORM golang:1.24 AS build
WORKDIR /src

# ...and cross-compiles for the TARGET.
ARG TARGETOS
ARG TARGETARCH

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/app

# Runtime stage: NO --platform. It must be the target's architecture.
FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

Three rules this encodes, each of which is a finding when violated:

1. `--platform=$BUILDPLATFORM` belongs on the **builder** stage only. Without it, `buildx` emulates the builder under QEMU and a Go build that takes 40 seconds takes 20 minutes
2. `--platform` must be **absent** from the runtime stage. Pinning it there, to anything, produces an image whose architecture does not match the manifest entry
3. `GOARCH=${TARGETARCH}` is what actually makes the binary arm64. Setting `--platform` without setting `GOARCH` gives you an arm64 *image* containing an amd64 *binary*, which passes a manifest check and fails with `exec format error`

**When cgo is required, this pattern needs a cross-compiler** and the simpler choice is often to stop cross-compiling:

```dockerfile
# Option A: cross-compile with an aarch64 C toolchain (fast, more setup)
FROM --platform=$BUILDPLATFORM golang:1.24 AS build
ARG TARGETARCH
RUN if [ "$TARGETARCH" = "arm64" ]; then \
      apt-get update && apt-get install -y --no-install-recommends gcc-aarch64-linux-gnu && \
      rm -rf /var/lib/apt/lists/*; fi
RUN CGO_ENABLED=1 GOOS=linux GOARCH=${TARGETARCH} \
    CC=$(if [ "$TARGETARCH" = "arm64" ]; then echo aarch64-linux-gnu-gcc; else echo gcc; fi) \
    go build -o /out/app ./cmd/app

# Option B: build natively on an arm64 machine (simple, needs an arm64 builder)
#   docker buildx build --platform linux/arm64 ... with an arm64 builder node,
#   or run the whole build on a Graviton CI runner. No --platform=$BUILDPLATFORM.
```

Option B is usually right once cgo is in play: the toolchain setup for Option A is per-library, and a Graviton CI runner removes the whole problem. Record which one was chosen and why.

Build and verify the manifest:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t myapp:multi --push .
docker buildx imagetools inspect myapp:multi | grep -i platform
```

### `GOAMD64` / `GOARM64`

```make
# Before - inert on arm64, but it means someone tuned for x86 and never tuned for arm64
GOAMD64 = v3
build:
	GOAMD64=$(GOAMD64) go build -o bin/app ./cmd/app

# After - each architecture gets its own level, neither leaks to the other
build:
	@case "$$(go env GOARCH)" in \
	  amd64) GOAMD64=v3 go build -o bin/app ./cmd/app ;; \
	  arm64) go build -o bin/app ./cmd/app ;; \
	  *)     go build -o bin/app ./cmd/app ;; \
	esac
```

Do **not** set `GOARM64` here. It is a Level-B recommendation in `06-runtime-configuration.md`: it raises the instruction baseline above `v8.0` and therefore pins the binary to a minimum Graviton generation, which is a fleet decision requiring measurement, not a migration fix.

### GoReleaser

```yaml
builds:
  - id: app
    main: ./cmd/app
    env:
      - CGO_ENABLED=0
    goos:   [linux]
    goarch: [amd64, arm64]      # arm64 added
    ldflags: ["-s -w"]

# Multi-arch image manifests, so one tag serves both
docker_manifests:
  - name_template: "{{ .Env.REGISTRY }}/app:{{ .Version }}"
    image_templates:
      - "{{ .Env.REGISTRY }}/app:{{ .Version }}-amd64"
      - "{{ .Env.REGISTRY }}/app:{{ .Version }}-arm64"
```

If `builds` has `goarch: [amd64]` and `dockers` publishes a single tag, adding `arm64` to `goarch` is necessary but not sufficient — without `docker_manifests`, consumers pulling the plain tag still get amd64.

### CI

```yaml
# GitHub Actions: native arm64 runners, no emulation
jobs:
  test:
    strategy:
      matrix:
        runner: [ubuntu-24.04, ubuntu-24.04-arm]
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version-file: go.mod }
      - run: go build ./...
      - run: go test ./...
      - run: go test -race ./...        # the arm64 leg of this is exit criterion 9
```

A matrix leg that runs `-race` on arm64 is the durable form of this skill's most important check: it turns a one-time migration finding into a permanent gate. Add it even when the current run is green.

For images, prefer native runners per architecture over `setup-qemu-action`; QEMU works and is roughly an order of magnitude slower, and for Go it is unnecessary because of the cross-compiling pattern above.

### Deployment descriptors

```yaml
# Lambda (SAM)
Resources:
  Fn:
    Type: AWS::Serverless::Function
    Properties:
      Runtime: provided.al2023
      Architectures: [arm64]          # absent means x86_64
      Handler: bootstrap
```

```bash
# The Lambda binary must be arm64 and named bootstrap for provided.al2023
GOOS=linux GOARCH=arm64 go build -tags lambda.norpc -o bootstrap ./cmd/fn
zip fn.zip bootstrap
```

```yaml
# ECS task definition
runtimePlatform:
  cpuArchitecture: ARM64            # absent means X86_64
  operatingSystemFamily: LINUX
```

```yaml
# Kubernetes: pin the architecture AND make sure the image manifest has it
spec:
  nodeSelector:
    kubernetes.io/arch: arm64
```

For EC2, Auto Scaling and launch templates, the instance type and the AMI are two separate changes and both are required: an arm64 instance type with an x86 AMI does not boot. Graviton families are `c7g`/`c8g` (compute), `m7g`/`m8g` (general), `r7g`/`r8g` (memory).

---

## 2.5 Behavioral Fixes

Resolves findings from `05-behavioral-findings.md`.

### Data races

A race the detector reports in Phase 3.2 is fixed here, with a synchronization primitive, and then re-verified:

```go
// Before - works on x86, intermittently wrong on arm64
type counter struct{ n int64 }
func (c *counter) inc() { c.n++ }
func (c *counter) get() int64 { return c.n }

// After
type counter struct{ n atomic.Int64 }   // Go 1.19+
func (c *counter) inc() { c.n.Add(1) }
func (c *counter) get() int64 { return c.n.Load() }
```

**Never** "fix" a race with a `time.Sleep`, a reordered statement, a channel buffer change, a `runtime.Gosched()`, or a `GOGC`/`GOMAXPROCS` setting. Those change the timing that made the race visible and leave the race in the program — which is worse than before, because the next person believes it was fixed. If the correct fix is beyond this transformation's scope (it requires redesigning ownership of a shared structure), that is a user decision, documented with the full detector output, and exit criterion 9 does not pass.

### CPU feature gates

```go
// Before - compiles on arm64, then disables the feature everywhere on Graviton
if cpu.X86.HasAVX2 {
    return sumAVX2(xs)
}
return nil, errors.New("unsupported CPU")

// After - arm64 gets the hardware path where one exists, and the portable path otherwise
switch {
case cpu.X86.HasAVX2:
    return sumAVX2(xs)
case cpu.ARM64.HasASIMD:
    return sumNEON(xs)
default:
    return sumGeneric(xs)
}
```

Where no arm64 implementation exists, the fix is the `default` branch calling a correct generic path — not an error. The arm64 feature bits available from `golang.org/x/sys/cpu` include `HasASIMD`, `HasAES`, `HasPMULL`, `HasSHA1`, `HasSHA2`, `HasCRC32`, `HasATOMICS`, `HasSVE`. On Graviton2 and later, `HasASIMD`, `HasAES`, `HasPMULL`, `HasSHA2`, `HasCRC32` and `HasATOMICS` are all present — but read the bit; do not hardcode the assumption.

### Syscall numbers

```go
// Before - syscall.SYS_OPEN does not exist on linux/arm64; this is a compile error (good)
fd, _, errno := syscall.Syscall(syscall.SYS_OPEN, uintptr(p), 0, 0)

// After - the portable call
fd, err := unix.Openat(unix.AT_FDCWD, path, unix.O_RDONLY, 0)
// or simply
f, err := os.Open(path)
```

For a numeric seccomp or BPF filter, switch to the name-based format or generate the numbers per architecture from `x/sys/unix`:

```go
// The number is architecture-dependent; the constant is not.
rule := seccomp.Rule{Syscall: unix.SYS_GETTID}   // resolves correctly on both
```

A filter pinned to `AUDIT_ARCH_X86_64` must gain an `AUDIT_ARCH_AARCH64` branch, or it fails closed (every syscall denied) or open (filter never matches) depending on the library — both are serious, and which one it is must be stated in the report.

### Page size

```go
// Before
buf := make([]byte, 4096)
off := addr & ^uintptr(4095)

// After
ps := os.Getpagesize()
buf := make([]byte, ps)
off := addr & ^uintptr(ps-1)
```

Where `4096` is a protocol constant, a disk block size or a buffer size rather than a page size, it is **not** a finding — leave it and say so in the report. Only the uses that interact with `mmap`, `mprotect`, page alignment or `madvise` matter.

### Floating point

```go
// Before - the test asserts a value produced by non-fused amd64 arithmetic
got := variance(xs)                        // internally: sum += (x-m)*(x-m)
if got != 2.9166666666666665 { t.Fatal(got) }

// After, option 1: force the rounding so both architectures agree.
//   An explicit conversion rounds to the target type, which prevents fusion.
acc += float64((x - m) * (x - m))

// After, option 2: compare with a tolerance (usually the better test anyway)
if math.Abs(got-want) > 1e-12 { t.Fatalf("got %v want %v", got, want) }
```

Option 2 is preferred for tests; option 1 for code where bit-identical cross-architecture output is a requirement (a checksum over floats, a reproducible-build guarantee, a value persisted and compared later). Note that option 1 costs the FMA's accuracy *and* speed on arm64 — the fused result is usually the more accurate one. Say which you chose and why.

Do not reach for a compiler flag or `GOEXPERIMENT` to disable fusion. There is no supported switch, and the spec permits the fusion.

### `CGO_ENABLED` and the resolver

If this transformation changed `CGO_ENABLED` from `1` to `0` — for any reason — record it in `05-behavioral-findings.md` as a behavior change needing user confirmation, with this text:

```markdown
**Behavior change: CGO_ENABLED 1 -> 0.** `net` now uses Go's own resolver
(reads /etc/resolv.conf directly, ignores /etc/nsswitch.conf and NSS modules)
and `os/user` reads /etc/passwd directly. Environments resolving names or users
through NSS (LDAP, SSSD, systemd-resolved stub behavior) will change behavior.
This is not an architecture difference; it is a consequence of the build change.
```

Going the other way (`0` to `1`) is equally a change and gets the same treatment.

---

## 2.6 Graviton Runtime Recommendations

Writes to `06-runtime-configuration.md`. **Document; do not apply.** Every item carries an evidence level:

- **Level A** — sourced from the repository or the Go documentation, correct by construction, zero measurement needed
- **Level B** — plausible for this workload, requires measurement on the target before adoption
- **N/A** — checked and does not apply here; say so, so the next reader does not re-derive it

| Recommendation | Level | Rationale |
|---|---|---|
| Instance family `c8g`/`m8g`/`r8g` (or `7g` where `8g` is unavailable in-region) matching the current family's class | A | the direct Graviton counterpart of the current family |
| Keep the current vCPU count as the starting point, then load test | A | every Graviton vCPU is a physical core with no SMT ([AWS Graviton performance testing](https://docs.aws.amazon.com/whitepapers/latest/aws-graviton-performance-testing/other-considerations.html)); an 8-vCPU Graviton instance has 8 physical cores where an 8-vCPU x86 instance has 4. Throughput per vCPU and scaling behavior both change, so an x86-calibrated autoscaling threshold is stale even when nothing fails |
| `GOMEMLIMIT` set to ~90% of the container memory limit | A | Go's GC is unaware of the cgroup limit; unrelated to architecture but routinely discovered during a migration. Only recommend it if the project does not already set it |
| `automaxprocs` (or an explicit `GOMAXPROCS`) when running under a CPU quota | A | `runtime.NumCPU()` reports host cores, not the quota, so `GOMAXPROCS` is wrong in a throttled container on both architectures. The instance-size change makes the error larger |
| `GOARM64=v8.2` | **B** | Go 1.23+. Raises the instruction baseline from the `v8.0` default. Graviton2 is Neoverse N1 (ARMv8.2-A), Graviton3 is V1 (ARMv8.4-A), Graviton4 is V2 (ARMv9.0-A), so `v8.2` is safe on Graviton2 and later — but it pins the binary's minimum generation, and the gain is workload-specific. Measure, and only set it if the fleet's oldest generation is known |
| Crypto-heavy workloads need no change | A | Go's `crypto/aes`, `crypto/sha256` and `crypto/sha512` use arm64 hardware instructions where the CPU reports them; Graviton2+ does. Often faster than the x86 path with no code change |
| `GOGC` tuning | B | no architecture-specific reason to change it. Only appears here if the project already tunes it, in which case the tuning was calibrated on x86 and should be re-measured |
| PGO profile regenerated on arm64 | B | only if the project uses profile-guided optimization (`default.pgo` present). An x86-collected profile is still valid input but describes x86 hot paths |

Check the two that depend on the repo:

```bash
ls -1 default.pgo cmd/*/default.pgo 2>/dev/null                              # PGO in use?
grep -rn -E 'GOMEMLIMIT|GOMAXPROCS|automaxprocs' . --exclude-dir=vendor 2>/dev/null   # already set?
```

---

## Phase 2 exit

- [ ] Every change traces to a named Phase 1 finding
- [ ] `go.mod`/`go.sum` changes, if any, each cite an arm64 blocker and its evidence
- [ ] `vendor/` re-vendored with `go mod vendor` if the project vendors and a dependency changed
- [ ] `vendor/` not hand-edited
- [ ] No `--platform` on a runtime stage; `$BUILDPLATFORM` only on builder stages
- [ ] `GOARCH=${TARGETARCH}` present wherever `--platform` is
- [ ] Phase 1.1 capture and 1.3 scan re-run after any dependency change
- [ ] `06-runtime-configuration.md` written, with nothing from it applied
- [ ] A commit per sub-step that changed files
