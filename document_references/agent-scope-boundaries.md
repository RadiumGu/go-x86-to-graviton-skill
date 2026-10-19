# ARM64 Transformation — Agent Scope Boundaries

**Read this before Phase 1.** It is the decision tree for every finding and the defence against the one failure mode that ruins Go Graviton migrations: a report full of changes that have nothing to do with arm64.

## Contents

- [Primary objective](#primary-objective)
- [The Go-specific trap](#the-go-specific-trap)
- [Quick reference: the Go decision tree](#quick-reference-the-go-decision-tree)
- [IN SCOPE: what to fix](#in-scope-what-to-fix)
- [OUT OF SCOPE: what not to fix](#out-of-scope-what-not-to-fix)
- [Should I update this dependency?](#should-i-update-this-dependency)
- [Recommendations: validation ladder](#recommendations-validation-ladder)
- [Verified non-issues in Go](#verified-non-issues-in-go)
- [Red flags: the agent is going off-scope](#red-flags-the-agent-is-going-off-scope)
- [How to document scope compliance](#how-to-document-scope-compliance)
- [Case studies](#case-studies)
- [Success criteria](#success-criteria)
- [When in doubt](#when-in-doubt)

---

## Primary objective

Make this Go module build and run correctly on AWS Graviton (linux/arm64), changing as little as possible, and prove it by executing on arm64.

Not: modernize the module. Not: patch vulnerabilities. Not: tidy the build. Not: make it faster. Each of those is a legitimate project and none of them is this one. Mixing them in makes the migration unreviewable, because a reviewer cannot tell which change was required and which was taste.

---

## The Go-specific trap

> **There is no such thing as an arm64 build of a Go module dependency.**

A Go dependency is source. `go.mod` records a version; `go.sum` records hashes of that source. Neither has an architecture dimension. The question "does version X of this dependency support arm64?" is almost always **malformed** — the right question is "does this dependency contain a file that builds for arm64?", which is a property of its build constraints, not its version number.

The Java and Python Graviton skills spend most of their effort on an availability question (does a `linux-aarch_64` classifier exist, does an `aarch64` wheel exist). **Transplanting that effort into Go produces pure noise.** An agent that has internalized the Python skill will:

- propose upgrading `github.com/stretchr/testify` from v1.8.4 to v1.10.0 "for ARM64 support" — testify is pure Go and every version works
- report a dependency as `CHECK: ARM64 support unverified` when the correct verdict is "pure Go, no architecture dimension, nothing to verify"
- run `go get -u ./...` and call the resulting 60-line `go.mod` diff a migration
- write a `03-dependency-compatibility-report.md` with 200 COMPATIBLE rows that carry no information

In the large majority of real Go migrations, **`go.mod` and `go.sum` are byte-identical before and after.** When they are, say so prominently — it is the headline result, not a gap in the work.

The three legitimate reasons for a dependency change, all of which must cite evidence:

1. The current version has **no file that builds for arm64** in a package you import (Shape C, Phase 1.3), and a newer version adds one
2. The current version **bundles a prebuilt C archive** with no arm64 member, and a newer version bundles one (Phase 1.2, Route 3)
3. The dependency has a **documented arm64-specific defect** fixed in a newer version — a real upstream issue you can link, not a plausible guess

Anything else is out of scope.

---

## Quick reference: the Go decision tree

```
A finding is in front of you. Ask, in order:

1. Does it stop `GOOS=linux GOARCH=arm64 go build ./...`?
   YES -> IN SCOPE, blocking. Fix it.
   NO  -> continue.

2. Does it stop the native arm64 build, with CGO_ENABLED as the deployment sets it?
   YES -> IN SCOPE, blocking (a cgo/toolchain/system-library issue). Fix it.
   NO  -> continue.

3. Does it make the program BEHAVE differently on arm64?
   (data race, FMA-fused float, syscall number, page size, CPU-feature gate
    with a bad else branch, CGO_ENABLED-driven resolver change)
   YES -> IN SCOPE. Fix the mechanism, not the symptom.
   NO  -> continue.

4. Does it select x86 in a build script, image, manifest or deployment descriptor,
   explicitly or by defaulting?
   YES -> IN SCOPE. Make it architecture-aware.
   NO  -> continue.

5. Does it produce an x86 artifact that lands in the arm64 build or runtime?
   (committed .a/.so, downloaded tool, single-arch base image)
   YES -> IN SCOPE. Re-source it for aarch64.
   NO  -> continue.

6. Is it a Graviton runtime setting?
   YES -> DOCUMENT in 06-runtime-configuration.md with an evidence level.
          Do NOT apply it.
   NO  -> continue.

7. Everything else -> OUT OF SCOPE. Do not touch it.
   Record it in 00-summary.md under "Observed, out of scope" if it is
   genuinely worth a human's attention. One line each, no fixes.
```

---

## IN SCOPE: what to fix

### 1. cgo and the C libraries it links
- an `#cgo` directive with an x86-only flag (`-msse*`, `-mavx*`, `-maes`, `-m64`, `-march=x86-64`)
- a linked system library with no aarch64 package installed in the build or runtime environment
- a bundled prebuilt archive with no arm64 member (version change permitted; cite the archive name)
- a missing C compiler in the arm64 builder image
- a C library downloaded at build time from an x86-only URL

### 2. Build constraints and assembly
- a package with no file that builds for arm64 (Shape C) — relax the gate, add a generic path, or upgrade the dependency that owns it
- an unsuffixed `.s` file with x86 mnemonics and no internal `//go:build` constraint
- a test file gated on `amd64`, which leaves the generic path untested
- a fallback implementation that is a stub, an error or a panic rather than a working portable path

### 3. Native artifacts
- a committed binary, `.so`, `.a` or `.o` that `file` reports as x86-64
- a binary downloaded by a Dockerfile, Makefile, CI job or `go:generate` from an architecture-naming URL
- a base image or tool image with no `linux/arm64` manifest entry

### 4. Build and deployment configuration
- `GOARCH=amd64` hardcoded in a Makefile, script, Dockerfile or CI job
- `GOAMD64` set unconditionally (remove or pair it; do not add `GOARM64` here)
- `--platform=linux/amd64` on any stage; `--platform=$BUILDPLATFORM` on a runtime stage; `--platform` present without `GOARCH=$TARGETARCH`
- `-march`/`-mtune` reaching an aarch64 compiler
- GoReleaser `goarch` missing arm64, or multi-arch builds without `docker_manifests`
- Lambda `Architectures`, ECS `runtimePlatform.cpuArchitecture`, K8s `kubernetes.io/arch`, instance types and AMIs — wrong **or absent**, because absent defaults to x86
- CI changes that only add or switch an architecture (a new matrix leg, an arm64 runner, a buildx platform)

### 5. Behavioral differences
- a data race reported by `go test -race` on arm64
- a `cpu.X86.*` gate whose `else` branch errors, panics or disables the feature
- a direct `syscall.SYS_*` number, or a numeric/`AUDIT_ARCH_X86_64`-pinned seccomp filter
- a hardcoded page size used for page-aligned operations, graded against the target's actual page size
- a test asserting exact float equality on a fusible expression
- a `CGO_ENABLED` change made during this transformation (document as a behavior change; get confirmation)

### 6. Documented arm64 defects
- an upstream issue, linked, describing an arm64-specific bug fixed in a newer version

---

## OUT OF SCOPE: what not to fix

### 1. Dependency modernization
```diff
- github.com/stretchr/testify v1.8.4
+ github.com/stretchr/testify v1.10.0      # "latest" - NOT a reason
```
Pure Go. Every version builds for arm64. `go get -u` is not part of this transformation.

### 2. Security updates
A CVE in a dependency is real and urgent and belongs in its own change. Folding it in here makes the migration diff impossible to review and ties a security fix to an architecture decision. Note it in `00-summary.md` under "Observed, out of scope" with the advisory ID.

### 3. Go version changes
Only through `go.toolchain_bump` in `skill-config.md`, and only when a toolchain bump is the sole route to an arm64 build. Being on a supported-but-not-latest Go release is not an arm64 finding. The only version floor that genuinely blocks an exit criterion is Go 1.14 for the race detector on `linux/arm64`, and no realistic project is below it.

### 4. Code refactoring
Not even when you are already editing the file. A one-line constraint change in a file you had to touch is the change; reformatting the function around it is not.

### 5. Linting, formatting and tooling adoption
`gofmt`, `goimports`, `golangci-lint`, a vet sweep, error-wrapping modernization, `interface{}` → `any`. None of it is arm64.

### 6. Base image family changes
alpine → debian, debian → distroless, any → `scratch`. Only in scope when the current family publishes **no** arm64 image at all, which is rare. "distroless would be smaller" is a different project.

### 7. Build system changes
Makefile → Taskfile, `go build` → GoReleaser, adding Bazel, restructuring multi-stage Dockerfiles beyond the architecture fix. Phase 2.4's cross-compiling pattern is an architecture fix to an existing Dockerfile, not a licence to rewrite it.

### 8. Performance work
Beyond documenting recommendations in `06-runtime-configuration.md`. Including: adding `GOARM64`, tuning `GOGC`, introducing PGO, replacing a library with a faster one, adding an arm64 assembly fast path where a correct generic path exists.

### 9. Pure-Go replacement of a working cgo dependency
Swapping `mattn/go-sqlite3` for `modernc.org/sqlite` removes the cgo problem and is often a good idea — and it changes the SQL engine implementation, the performance profile and the failure modes. User decision, with the options written out. Never applied unilaterally.

### 10. `.gitignore` / `.dockerignore` / editor config / CI unrelated to architecture

---

## Should I update this dependency?

```
A dependency is in front of you.

Does a package you import from it have NO file that builds for arm64?
  (Confirmed by: "build constraints exclude all Go files" in
   raw/go-list-deps-arm64.err, or an undefined symbol from a _amd64.go file)
  |
  +-- YES -> Does a newer version add an arm64 or generic path?
  |          (Confirmed by: finding the file in the module cache for that version)
  |          |
  |          +-- YES -> MUST UPGRADE. Lowest version that has it. Cite the file name.
  |          +-- NO  -> Is a purego/noasm build tag offered?
  |                     +-- YES -> propose the tag (global effect: document it)
  |                     +-- NO  -> USER DECISION: fork, replace, or keep on x86
  |
  +-- NO -> Does it bundle a prebuilt C archive with no arm64 member?
            (Confirmed by: ar/file on the archives in the module cache)
            |
            +-- YES -> Does a newer version bundle an arm64 archive?
            |          +-- YES -> MUST UPGRADE. Cite the archive file name.
            |          +-- NO  -> is a dynamic-linking tag offered? -> USER DECISION
            |
            +-- NO -> Is there a LINKED upstream issue describing an
                      arm64-specific defect fixed in a newer version?
                      |
                      +-- YES -> MUST UPGRADE. Link the issue.
                      +-- NO  -> **COMPATIBLE. DO NOT TOUCH IT.**
                                 It is pure Go, or it already has an arm64 path.
                                 Its version is irrelevant to this migration.
```

The bottom-right leaf is where the overwhelming majority of dependencies land. That is the expected outcome, not a sign the analysis was shallow.

---

## Recommendations: validation ladder

Everything in `06-runtime-configuration.md` carries one of these, and the level is part of the recommendation:

| Level | Meaning | Example |
|---|---|---|
| **A** | Sourced from the repository or official documentation; correct by construction | "use `c8g` where the service runs `c6i`"; "`GOMEMLIMIT` at ~90% of the container limit, because Go's GC does not read the cgroup limit" |
| **B** | Plausible for this workload; requires measurement on the target first | "`GOARM64=v8.2`"; "re-tune `GOGC`"; "regenerate the PGO profile on arm64" |
| **N/A** | Checked and does not apply here | "no PGO profile in the repo"; "`GOMAXPROCS` already set via `automaxprocs`" |

Writing an `N/A` line is worth as much as writing a recommendation: it tells the next reader the question was asked.

A Level-B item presented without its level, or applied rather than documented, is a scope violation.

---

## Verified non-issues in Go

State these as non-issues when they come up, so the report does not carry phantom risk:

| Thing | Why it is not a finding on linux/arm64 |
|---|---|
| A pure-Go dependency's version | no architecture dimension exists |
| `go.sum` contents | hashes of source, architecture-independent |
| `int`, `uintptr`, pointer width | 64-bit on both amd64 and arm64 (LP64) |
| `sync/atomic` 64-bit field alignment | the classic alignment panic is a 32-bit (`GOARCH=arm`, `386`) problem |
| `unsafe.Sizeof`/`Alignof` of a struct | identical on amd64 and arm64 |
| `go:embed` | file contents, not code |
| Integer and `math/big` arithmetic | exact on both |
| Goroutines, channels, GC, scheduler semantics | architecture-independent by specification |
| Go's memory model, for a **race-free** program | architecture-independent by specification. The caveat is the whole of class 4 |
| `encoding/json`, `net/http`, `database/sql` and the rest of the stdlib | portable; a stdlib package is never the arm64 finding |
| Endianness | both amd64 and arm64 on Linux are little-endian. A big-endian bug is a different port (`s390x`, `ppc64`) |

The endianness row matters: an agent reaching for "arm is big-endian" is working from a decades-stale fact. AArch64 on Linux is little-endian, so byte-order bugs do **not** surface in this migration.

---

## Red flags: the agent is going off-scope

Stop and re-read this file if any of these is true of the work in progress:

1. `go.mod` has more than three changed lines and they are not each traced to a Phase 1.2 or 1.3 finding
2. `go get -u` or `go get -u=patch` was run
3. `03-build-constraint-report.md` or a dependency table contains rows with no evidence column
4. A dependency is labelled `CHECK` because "arm64 support could not be verified" — for pure Go there is nothing to verify
5. `gofmt`, `goimports` or a linter touched files the findings did not name
6. A base image was changed and no Phase 1.4 finding says the old one lacks arm64
7. A Go version was raised and no finding says it was the only route to an arm64 build
8. `CGO_ENABLED` was set to `0` to make a link error go away, and the deployment does not set it to `0`
9. A build constraint was **removed** rather than widened, or an amd64 fast path was deleted
10. A data race was "fixed" with a sleep, a reordering, a `Gosched`, or a runtime setting
11. `vendor/` was hand-edited
12. A recommendation from `06-runtime-configuration.md` was applied
13. A `-race` failure was reported as `PASS` with a note, or an un-run check was reported as `PASS`
14. The report's dependency table has more rows than the repo has direct dependencies, and every row says COMPATIBLE

Red flag 14 deserves a note: a 200-row table of COMPATIBLE transitive dependencies is not thoroughness. It is the Python skill's shape applied where it carries no information, and it buries the four findings that matter.

---

## How to document scope compliance

### For changes made

```markdown
## ARM64-Required Changes

| # | Finding (report, section) | Change | Evidence |
|---|---|---|---|
| 1 | 03 §Shape C, `internal/simd` | `//go:build amd64` -> `amd64 \|\| arm64`; renamed `simd_amd64.go` -> `simd_asm.go` | `raw/go-list-deps-arm64.err:12` `build constraints exclude all Go files in ./internal/simd` |
| 2 | 02 §Route 3, `confluent-kafka-go` | v2.1.1 -> v2.3.0 | v2.3.0 module cache contains `librdkafka_glibc_linux_arm64.a`; v2.1.1 does not |
| 3 | 04 §Dockerfile | `FROM --platform=linux/amd64 alpine:3.20` -> `FROM alpine:3.20` | `raw/image-platforms.txt`: `alpine:3.20  linux/amd64,linux/arm64,...` |
```

### For changes NOT made

```markdown
## Validated as ARM64-Compatible (No Changes)

- **All 47 module dependencies**: pure Go, no architecture dimension. `go.mod` and
  `go.sum` are unchanged. Verified by `raw/go-list-deps-arm64.json` resolving the
  full set with no error and no `CgoFiles` in any package.
- `internal/hash`: Shape A — `hash_amd64.s` and `hash_arm64.s` both present.
- `internal/compress`: Shape B — `compress_amd64.go` with `compress_generic.go`
  gated `//go:build !amd64`. Builds and is functionally equivalent; benchmark
  delta recorded in 07. Deliberately not changed.

## Observed, Out of Scope

- `golang.org/x/net` v0.17.0 is affected by GHSA-xxxx-xxxx. Unrelated to arm64;
  belongs in a separate change.
- 14 packages have no tests. Unrelated to arm64.
```

The second section is as important as the first. A reviewer needs to see that the absence of changes was a conclusion, not an omission.

---

## Case studies

### Case study: the empty dependency report is the correct one

A 60-dependency Go service, containerized, no cgo. Phase 1.2 returns zero cgo packages; Phase 1.3 finds two Shape A families in `golang.org/x/crypto` and nothing else; `go.mod` needs no change. The entire migration is one Dockerfile (cross-compiling multi-stage pattern), one CI matrix leg, and `Architectures: [arm64]` in the SAM template.

The failure mode here is an agent that finds this *unsatisfying* and goes looking for work: upgrading dependencies, switching the base image, adding `GOARM64`, rewriting the Makefile. Every one of those changes adds review burden and risk to a migration that was already done. **A three-file diff is the correct deliverable and should be presented as a success.**

### Case study: the Shape C file in a dependency, not in your code

`go build` for arm64 fails with `build constraints exclude all Go files in /go/pkg/mod/github.com/example/fastjson@v0.3.1/internal/simd`. The project's own source is clean.

Wrong fixes: patch the module cache (wiped on the next download); hand-edit `vendor/` (reverted by `go mod vendor`); vendor the dependency and patch it (now you maintain it); set `CGO_ENABLED=0` (unrelated, and it does not help).

Right fix, in order: check `go list -m -versions github.com/example/fastjson` for a newer version, download a candidate, confirm the arm64 or generic file exists in it, `go get` that version, re-vendor if vendored, re-run the Phase 1 capture. If no version has it, it becomes a user decision with a `replace`-to-fork option and a drop-the-dependency option.

The upgrade is in scope here precisely because it cites a build failure. The same upgrade with no build failure behind it is red flag 1.

### Case study: the race that only Graviton shows

A service migrated cleanly: cross-build passed, native build passed, `go test ./...` passed on Graviton, container built, startup fine. It was declared done and deployed. Three days later it began returning occasional stale cache entries, only on the Graviton fleet.

`go test -race ./...` on arm64 reports a data race in `internal/cache`: an unsynchronized map read concurrent with a write, in code that had been in production on x86 for two years. On x86's Total Store Order the window was narrow enough never to be observed; on arm64 it is not.

Two lessons. First, exit criterion 9 is not ceremony — it is the only step in this skill that would have caught this before deployment. Second, the fix is a `sync.RWMutex` or a `sync.Map`, in `internal/cache`, and it is a **pre-existing defect**: the correct report says the migration surfaced a two-year-old race, not that arm64 introduced one. That framing matters, because the alternative framing ("Graviton broke our cache") leads to a rollback instead of a fix.

### Case study: the arm64 image with the amd64 binary

A Dockerfile gained `--platform=$BUILDPLATFORM` on its builder stage, as every guide recommends. `docker buildx imagetools inspect` showed both platforms. The image pushed, the ECS task definition got `cpuArchitecture: ARM64`, the task started — and died with `exec format error`.

`--platform=$BUILDPLATFORM` made the builder native, which is correct and fast. But the `go build` line inside it had no `GOARCH`, so it built for the **builder's** architecture, amd64, and copied an amd64 binary into an arm64 runtime stage. The manifest was right. The layer was right. The binary was not.

`GOARCH=${TARGETARCH}` is the line that makes the binary arm64. `--platform` alone never does. And the check that catches it is not `image inspect` — it is `file` on the binary extracted from the image (Phase 3.3).

**The false-accusation half of this case study, measured.** An earlier version of this
skill reported any Dockerfile carrying `--platform` with no literal `GOARCH=$TARGETARCH`
as defective. Run against containerd's `.github/workflows/release/Dockerfile`, that
produced a false accusation on idiomatic code: the file uses
[tonistiigi/xx](https://github.com/tonistiigi/xx), where `xx-go --wrap` derives `GOARCH`
from `$TARGETPLATFORM` and `xx-verify` then checks the output binary's architecture. There
is no literal `GOARCH=$TARGETARCH` anywhere and the Dockerfile is correct.

So the rule is: a `--platform` build needs *something* that sets `GOARCH` for the target,
and a cross-compile wrapper counts. Recognize `xx-go`, `xx-info`, `xx-verify`, `--wrap`,
GoReleaser and `ko` before claiming the defect - then confirm the binary's architecture in
Phase 3.3 regardless, because that check is cheap and settles it either way.

### Case study: the dependency upgrade that was not a fix

An agent reported: *"Updated 23 dependencies to their latest versions for ARM64 compatibility. All tests pass."* The `go.mod` diff was 23 lines; the arm64 build had been passing before any of them.

Every one of the 23 was pure Go. Not one was a finding. The transformation's actual required changes were a Dockerfile `--platform` removal and an `Architectures` field — two lines, invisible inside a 23-line dependency diff that a reviewer now has to evaluate on its own merits, against a claim ("for ARM64 compatibility") that is false for all 23.

This is the single most common way this skill is misapplied, and it is why the Go thesis is at the top of `SKILL.md`.

---

## Success criteria

The transformation succeeded when:

1. `GOOS=linux GOARCH=arm64 go build ./...` passes
2. A native arm64 build passes with the deployment's `CGO_ENABLED`
3. `go test ./...` and `go test -race ./...` both pass **on real arm64 hardware**, or any failure is classified and any un-run check is recorded as `NOT RUN`
4. The application starts on arm64 and `runtime.GOARCH` reports `arm64`
5. **Every change traces to a named finding.** A reviewer reading the diff alongside `graviton-validation/` can account for every line
6. `go.mod`/`go.sum` are unchanged, or each change cites an arm64 blocker with evidence
7. Nothing from `06-runtime-configuration.md` was applied
8. Out-of-scope observations are listed, not fixed

Criterion 5 is the one that distinguishes a usable deliverable from an unreviewable one.

---

## When in doubt

| Situation | Do |
|---|---|
| Unsure whether a dependency needs changing | Assume not. The default for a Go dependency is COMPATIBLE |
| Unsure whether a finding is arm64-specific | Run it on the x86 baseline at the same commit. If it fails there too, it is `PRE-EXISTING` |
| Unsure whether a fallback implementation is equivalent | Read its body. Do not infer from its name |
| Unsure whether to substitute a cgo library | Do not. Write it up as a user decision with options and costs |
| Unsure whether a check ran on real hardware | It did not. Write `NOT RUN` |
| Unsure whether a change is in scope | Leave it out and list it under "Observed, out of scope" |
| A race report you cannot fix within scope | `NOT RUN`/`FAIL` on criterion 9, full detector output in the report, and a user decision. Never a sleep |
