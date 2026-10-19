# ARM64 Transformation — Documentation Standards

Defines the mandatory `graviton-validation/` output folder, the canonical filenames, and the required sections of each file. **Read before Phase 1.**

## Contents

- [Purpose](#purpose)
- [Output folder structure](#output-folder-structure)
- [Agent instructions](#agent-instructions)
- [File specifications](#file-specifications)
- [Raw file specifications](#raw-file-specifications)

---

## Purpose

The reports exist so a reviewer can account for **every line of the diff** without re-doing the analysis. That is the deliverable, equally with the code change: a migration whose changes cannot be traced to findings is unreviewable, and an unreviewable migration gets reverted the first time anything goes wrong on the new fleet.

Two properties every file must have:

1. **Every verdict cites its evidence** — a command's output, a file path and line, a registry listing, a `file` result. "Verified compatible" with no citation is not a verdict
2. **Every result names the environment it came from** — a cross-compiled pass and a Graviton-native pass are different facts, and the exit criteria distinguish them

---

## Output folder structure

```
graviton-validation/
├── 00-summary.md                              Executive summary and exit criteria
├── 01-project-assessment.md                   Build system, layout, Go version, target OS/libc/page size
├── 02-cgo-report.md                           cgo packages, C libraries, routes, verdicts
├── 03-build-constraint-report.md              Architecture-constrained files by shape
├── 04-artifact-and-build-config-findings.md   Binaries, images, build scripts, deployment descriptors
├── 05-behavioral-findings.md                  Races, CPU gates, syscalls, page size, floats, CGO_ENABLED
├── 06-runtime-configuration.md                Graviton recommendations (documented, NOT applied)
├── 07-build-test-results.md                   Build, vet, test, race, container, startup
└── raw/
    ├── go-list-deps-arm64.json                Authoritative resolved set for arm64
    ├── go-list-deps-arm64.err                 Constraint errors - read this first
    ├── go-list-deps-amd64.json                x86 baseline resolved set
    ├── go-list-deps-amd64.err                 x86 baseline errors, for classification
    ├── module-graph.txt                       go mod graph
    ├── main-packages.txt                      Deployed binaries
    ├── dockerfiles.txt                        Every Dockerfile found, incl. non-standard names
    ├── cgo-packages.txt                       One line per cgo package with its C flags
    ├── build-constraints.txt                  One line per architecture-constrained file
    ├── assembly-inventory.txt                 Every .s file with its implied architecture
    ├── native-artifact-scan.txt               Every committed native file with its architecture
    ├── image-platforms.txt                    Every referenced image with its registry platforms
    ├── image-native-scan.txt                  Every native file inside the built arm64 image
    ├── arm64-crossbuild.log                   Cross-compile output
    ├── arm64-build.log / amd64-build.log      Native build output, both architectures
    ├── arm64-vet.log / amd64-vet.log          go vet output, both architectures
    ├── arm64-test.log / amd64-test.log        go test output, both architectures
    ├── arm64-race.log                         go test -race output - full detector reports
    ├── arm64-startup.log                      Startup output
    └── arm64-bench.txt / amd64-bench.txt      Optional benchmark comparison
```

Create it before Phase 1:

```bash
mkdir -p graviton-validation/raw
```

---

## Agent instructions

1. **Create the folder before Phase 1.** A report written at the end from memory loses the evidence
2. **Write each file as its phase runs**, not at the end
3. **Use the canonical filenames above.** A differently-named file is an exit-criterion failure (criterion 15)
4. **Every table row carries an evidence column.** No exceptions
5. **`NOT RUN` is a valid verdict.** Writing `PASS` for a check that did not run is the one unrecoverable error in this document set
6. **Keep raw output verbatim.** Do not summarize a race detector report, a build error or a `file` output — the detail is the fix
7. **Say "no findings" explicitly** when a section has none. An empty section reads as unfinished work; `No findings.` reads as a conclusion
8. **Split each report into Required / Improvement / Compatible**, so a reviewer can read only the first part and know whether to ship

---

## File specifications

### `00-summary.md` — Transformation Summary

The only file most readers will open. Lead with the decision a human has to make.

```markdown
# ARM64 Compatibility Validation — Summary

## Headline

<One sentence: did this module migrate, and what is the one thing a human must decide?>

Build:  PASS (native, Graviton c7g.xlarge / Amazon Linux 2023)
Race:   <PASS (N runs) | 1 DATA RACE in internal/cache | NOT RUN - no arm64 hardware>
cgo:    <none | 2 packages, both resolved | 1 BLOCKER - user decision required>
Deps:   <go.mod unchanged | 1 change, cited below>

## Project Overview

| | |
|---|---|
| Module | `github.com/org/service` |
| Deployed binaries | `./cmd/api`, `./cmd/worker` |
| Go version (source) | 1.24.0 (Dockerfile builder `golang:1.24`) |
| Build system (release path) | Makefile -> docker buildx |
| Deployment | ECS Fargate, `amazonlinux:2023` runtime image |
| Target | linux/arm64, glibc 2.34, 4 KB pages |
| cgo | required / optional / none |
| Dependencies | 47 modules, 0 using cgo |

## Exit Criteria

| # | Criterion | Verdict | Environment / Evidence |
|---|---|---|---|
| 1 | arm64 cross-build | PASS | `raw/arm64-crossbuild.log`, x86 host |
| 2 | native arm64 build, deployment CGO_ENABLED | PASS | `raw/arm64-build.log`, c7g.xlarge / AL2023 |
| 3 | cgo C libraries aarch64 | N/A | no cgo (02) |
| 4 | constrained files have arm64/generic path | PASS | 03, 2 Shape A families, 0 Shape C |
| 5 | go vet diff vs x86 | PASS | `raw/*-vet.log`, identical |
| 6 | container arm64, no x86 natives | PASS | `raw/image-native-scan.txt`, 1 ELF, aarch64 |
| 7 | go.mod/go.sum unchanged or cited | PASS | unchanged |
| 8 | go test on arm64 | PASS | `raw/arm64-test.log`, c7g.xlarge |
| 9 | **go test -race on arm64, no race** | **FAIL** | `raw/arm64-race.log`, 1 race in `internal/cache` |
| 10 | failures classified | PASS | 07 |
| 11 | no arm64 test failures | PASS | 07 |
| 12 | starts on arm64, GOARCH=arm64 | PASS | `raw/arm64-startup.log` |
| 13 | ldd resolves aarch64 | N/A | static binary |
| 14 | Go version unchanged | PASS | 01 |
| 15 | canonical report filenames | PASS | this folder |

## Changes Made

| # | Finding | Change | Evidence |
|---|---|---|---|
| 1 | 04 §Dockerfile | removed `--platform=linux/amd64`; added `ARG TARGETARCH` + `GOARCH=$TARGETARCH` | `raw/image-platforms.txt` |
| 2 | 04 §Deployment | ECS task definition `runtimePlatform.cpuArchitecture: ARM64` | was absent (defaults X86_64) |
| 3 | 04 §CI | added `ubuntu-24.04-arm` matrix leg running `-race` | — |

## Validated as Compatible (No Changes)

- All 47 dependencies: pure Go, no architecture dimension. `go.mod`/`go.sum` unchanged.
- `internal/hash`: Shape A, `hash_amd64.s` + `hash_arm64.s` both present.
- `internal/compress`: Shape B, generic fallback verified as a real implementation.

## Recommendations Recorded (Not Applied)

See `06-runtime-configuration.md`. 3 Level A, 2 Level B, 2 N/A. None applied.

## Remaining Concerns

1. **Data race in `internal/cache`** (criterion 9). Pre-existing: the same race
   reproduces on the x86 baseline at this commit under `-race`, and the project's
   CI has never run `-race`. arm64 is where it becomes observable in production.
   Full detector output in 07. **Requires a decision before deploying to Graviton.**
2. Shape B in `internal/compress` loses the AVX2 path. Benchmark delta recorded
   in 07; load testing is the user's.

## Observed, Out of Scope

- `golang.org/x/net` v0.17.0 is affected by GHSA-xxxx-xxxx. Unrelated to arm64.
- 14 packages have no tests. Unrelated to arm64.
```

### `01-project-assessment.md` — Project & Environment Assessment

Required sections:

```markdown
# Project Assessment

## Build Systems Present
<Every one detected, and WHICH ONE SHIPS. The shipping one is what Phase 3 validates.>

## Module Layout
<single module / multi-module / workspace / vendored. Member list if applicable.>

## Deployed Binaries
<from raw/main-packages.txt>

## Go Version
| Source | Value |
|---|---|
| `go.mod` `go` directive | 1.21 |
| `go.mod` `toolchain` | (absent) |
| Dockerfile builder image | `golang:1.24` |
| CI `setup-go` | `go-version-file: go.mod` |
| **Decided by** | Dockerfile builder: **1.24** |

Support status: <looked up, with the source>. arm64-relevant floors: <from Phase 1.6>.

## Deployment Type
<container / Lambda / EC2 binary / multiple>

## Target OS, C Library and Page Size
| | |
|---|---|
| Runtime image | `amazonlinux:2023` |
| C library | glibc 2.34 |
| Page size | 4096 (`getconf PAGESIZE` on the target) |
| Static binary required | no |

## CGO_ENABLED (as the deployment sets it)
<value, and where it is set. This decides Phase 3's build and the race run.>

## Build Tags (as the deployment passes them)
<any -tags, and where. The constraint analysis must use these.>

## Private Modules / Proxy
<GOPRIVATE, GOPROXY, and whether every module resolved. An unresolved module is a CHECK.>

## Skill Configuration Overrides Applied
<from skill-config.md, or "none - skill-config.md not present">

## Component Risk Categorization
| Component | Type | cgo | Constrained files | Native artifacts | Initial risk |
```

### `02-cgo-report.md` — cgo and C Dependencies

```markdown
# cgo Report

## Summary
<"No package in the resolved dependency set uses cgo." is a complete and excellent
 result. State it plainly with the evidence, then the CGO_ENABLED caveat.>

cgo packages: N (from raw/cgo-packages.txt)
Builds with CGO_ENABLED=0: yes / no
Classification: PURE GO / CGO-OPTIONAL / CGO-REQUIRED

## cgo Packages
| Package | C files | C libraries | Route | Verdict | Evidence |
|---|---|---|---|---|---|

## C Libraries
| Library | Route | aarch64 available | Verdict | Evidence |
|---|---|---|---|---|
<Route per cgo-and-native-dependencies.md. Evidence = distro index line, archive
 file name, release asset listing, or "vendored C source, no availability question".>

## x86-Only #cgo Flags
| File:line | Flag | Change |
|---|---|---|

## BLOCKER - User Decision Required
<Per blocker: the finding, its evidence, three options with their costs.
 Omit the section if there are none - do not write a placeholder.>

## Resolution Details (Phase 2.1)
<What was changed, per library, with the before/after and the re-verification.>

## No Findings
<Use when the section is empty: "No cgo usage in the resolved dependency set.">
```

### `03-build-constraint-report.md` — Build Constraints and Assembly

```markdown
# Build Constraint and Assembly Report

## Summary
Constrained files: N (raw/build-constraints.txt) | Assembly files: N (raw/assembly-inventory.txt)
Shape A (fine): N | Shape B (slower, non-blocking): N | Shape C (BLOCKER): N
vendor/ scanned: yes

## Shape C - BLOCKING
| Package | File(s) | Owner (project / dependency) | Fix | Evidence |
|---|---|---|---|---|
<Evidence MUST be the go list error line: raw/go-list-deps-arm64.err:NN>

## Shape B - Builds, Possibly Slower (non-blocking, NOT changed)
| Package | amd64 file | Fallback file | Fallback verified as | Benchmark note |
|---|---|---|---|---|
<"Fallback verified as" = real implementation / slower-but-correct / STUB / PANIC.
 The last two are findings, not Shape B.>

## Shape A - Ported (no action)
| Package | amd64 | arm64 |
|---|---|---|

## Assembly Inventory
| Architecture | File count |
|---|---|
<Plus a line for every UNSUFFIXED .s file and what was found inside it.>

## Test Files Gated on amd64
<Each one leaves a generic path untested. A finding.>

## Changes Applied (Phase 2.2)

## No Findings
```

### `04-artifact-and-build-config-findings.md`

```markdown
# Native Artifacts and Build Configuration

## Committed Native Artifacts
| Path | `file` output | Verdict | Resolution |
|---|---|---|---|

## Binaries Downloaded at Build / Deploy / Run Time
| Where (file:line) | Tool | URL architecture | Verdict | Resolution |
|---|---|---|---|---|

## Image Platforms
| Image | Registry platforms | Verdict |
|---|---|---|
<From raw/image-platforms.txt. CHECK is a valid value when no runtime or no login.>

## Dockerfile Findings
| File:line | Finding | Change |
|---|---|---|
<`--platform=linux/amd64`; `$BUILDPLATFORM` on a runtime stage; `--platform` with
 no `GOARCH=$TARGETARCH`; a missing C compiler for a cgo build.>

## Build Scripts
| File:line | Setting | Change |
|---|---|---|
<GOARCH pins, GOAMD64, -march/-mtune, GoReleaser goarch, Bazel platforms.>

## Deployment Descriptors
| File:line | Platform | Current | Required | Note |
|---|---|---|---|---|
<"absent" is a finding: absent defaults to x86 nearly everywhere.>

## CI
| File:line | Change |
|---|---|

## Changes Applied (Phase 2.3, 2.4)

## No Findings
```

### `05-behavioral-findings.md`

The file that earns this skill its keep. Lead with the race result.

```markdown
# Behavioral Findings

## Data Races
Project CI runs `-race`: yes / **no (the risk is unmeasured)**
Race run environment: <Graviton c7g.xlarge | NOT RUN - reason>
Races observed: N in M runs

### Race 1: internal/cache
<FULL verbatim detector output: both stacks, read and write, creating stacks.
 Do not summarize it - that output is the fix.>

Reproduces on x86 baseline at the same commit: yes / no
Classification: ARM64 (PRE-EXISTING-ROOT-CAUSE)
Resolution: <the synchronization added, or "user decision - see below">

## CPU Feature Dispatch
| File:line | x86 bit read | arm64 bit read | Final branch | Verdict |
|---|---|---|---|---|
<Verdict turns on the final branch: generic implementation = fine;
 error/panic/feature-disabled = finding.>

## Syscall Numbers and seccomp
| File:line | Form | Portable | Fails open / closed | Change |
|---|---|---|---|---|

## Page Size
Target page size: 4096 (from 01)
| File:line | Used for | Verdict |
|---|---|---|
<Only page-granular uses are findings. Say so for the others.>

## Floating Point (FMA fusion)
| File:line | Expression / assertion | Verdict | Change |
|---|---|---|---|

## CGO_ENABLED
Before: 1 | After: 1 | Changed: no
<If changed, the behavior-change block from Phase 2.5 goes here verbatim, with
 an explicit request for user confirmation.>

## Concurrency Sizing Assumptions
<NumCPU()/2 heuristics and similar. Reported, not changed; a note in 06.>

## Verified Non-Issues
<Endianness (both little-endian), int width (64-bit both), struct layout
 (identical), 64-bit atomic alignment (a 32-bit concern). Stating these prevents
 phantom findings in review.>

## No Findings
```

### `06-runtime-configuration.md` — Graviton Runtime Recommendations

**Nothing in this file is applied.** Every row carries a level.

```markdown
# Graviton Runtime Configuration (recommendations only — none applied)

## Instance Family
| Current | Recommended | Level | Rationale |
|---|---|---|---|

## Sizing and Concurrency
| Recommendation | Level | Rationale |
|---|---|---|
<Every Graviton vCPU is a physical core (no SMT), so an 8-vCPU Graviton instance
 has 8 physical cores where an 8-vCPU x86 instance has 4. Keep the vCPU count as
 the starting point and load test. Cite the AWS whitepaper.>

## Go Runtime Settings
| Setting | Current | Recommended | Level | Rationale |
|---|---|---|---|---|
<GOMEMLIMIT, GOMAXPROCS/automaxprocs: Level A when unset. GOGC: Level B.>

## GOARM64
| | |
|---|---|
| Level | **B — measure first** |
| Available | Go 1.23+ |
| Default | v8.0 |
| Candidate | v8.2 (safe on Graviton2 and later) |
| Cost | pins the binary's minimum Graviton generation |
| Decision owner | the user, after measurement and after confirming the fleet's oldest generation |

## Crypto
<Level A: Go's crypto uses arm64 hardware instructions where the CPU reports them;
 Graviton2+ does. Usually faster with no change.>

## PGO
<Level B if default.pgo is present; N/A if not. Say which.>

## Not Applicable
<Every item checked and ruled out, with why. An N/A line is worth as much as a
 recommendation: it shows the question was asked.>
```

### `07-build-test-results.md` — Build, Test and Startup Results

```markdown
# Build and Test Validation Results

## Environments Used
| Purpose | Environment | What it can prove |
|---|---|---|
| Cross-build | x86 laptop, Go 1.24 | criterion 1 only |
| Native build, test, race | Graviton c7g.xlarge, Amazon Linux 2023, Go 1.24 | criteria 2, 5, 8-13 |
| Container | same | criterion 6 |
<Toolchain differences from the deployment's qualify every result below. Say so here.>

## Build Attempts
| # | Command | Environment | Result | Log |
|---|---|---|---|---|
<Include the DEPLOYMENT'S OWN build command, not only `go build ./...`.>

## Build Failure Classification
| Failure | Label | Evidence (x86 baseline behavior) |
|---|---|---|

## go vet
<Only the diff against the x86 baseline matters. Show the diff or state it is empty.>

## Test Execution
| Command | Environment | Pass | Fail | Skip | Log |
|---|---|---|---|---|---|

## Test Failure Classification
| Test | Label | Evidence |
|---|---|---|
<INFRA / ARM64 / PRE-EXISTING. Every label needs the x86 baseline comparison.>

## Race Detector (criterion 9)
| | |
|---|---|
| Environment | <must be real arm64 hardware, named> |
| Command | `go test -race -count=N ./...` |
| Runs | N |
| Races observed | N |
| Log | `raw/arm64-race.log` |
<Full detector output per race. Cross-reference 05.>

## Results That Changed Without Failing
| Thing | x86 | arm64 | Explanation |
|---|---|---|---|

## Final Build (scoring basis)
<Which run the exit criteria are scored against, and which tests were skipped as
 INFRA. A run that skipped every test is never the final build.>

## Container Validation
| Check | Result | Evidence |
|---|---|---|
<Declared image architecture; the BINARY's architecture from `file`; every native
 file inside the image from raw/image-native-scan.txt; the multi-arch manifest.>

## Startup Validation
| Check | Result |
|---|---|
<runtime.GOARCH; file on the binary; ldd resolution; a real request served;
 no SIGILL/SIGBUS/exec format error.>

## Benchmarks (optional)
<Data, not a conclusion. benchstat output if collected.>
```

---

## Raw file specifications

| File | Produced by | Must contain |
|---|---|---|
| `go-list-deps-arm64.json` | 1.1 | `go list -deps -json` stdout for `GOARCH=arm64`. Non-empty; `grep -c '"ImportPath"'` > 0 |
| `go-list-deps-arm64.err` | 1.1 | its stderr, verbatim. **The constraint blockers live here** |
| `go-list-deps-amd64.{json,err}` | 1.1 | the same for `GOARCH=amd64`, for classification |
| `module-graph.txt` | 1.1 | `go mod graph` stdout |
| `main-packages.txt` | 1.1 | one import path per deployed binary |
| `dockerfiles.txt` | 1.1 | one path per Dockerfile, including non-standard names; `UNRESOLVED:` lines resolved by hand |
| `cgo-packages.txt` | 1.2 | one line per cgo package: import path, cgo file count, LDFLAGS, CFLAGS, pkg-config |
| `build-constraints.txt` | 1.3 | one line per constrained file, prefixed `SUFFIX` or `CONSTRAINT`; includes `vendor/` |
| `assembly-inventory.txt` | 1.3 | one line per `.s` file: implied architecture, path. `UNSUFFIXED` entries investigated |
| `native-artifact-scan.txt` | 1.4 | one line per committed native file: path, `file -b` output |
| `image-platforms.txt` | 1.4 | one line per image: reference, comma-separated platforms or `CHECK` |
| `image-native-scan.txt` | 3.3 | one line per native file inside the built arm64 image: path, `file -b` output |
| `arm64-crossbuild.log` | 3.1 | cross-compile output plus its exit status |
| `arm64-build.log`, `amd64-build.log` | 3.1 | native build output per architecture, plus exit status |
| `arm64-vet.log`, `amd64-vet.log` | 3.1 | `go vet` output per architecture |
| `arm64-test.log`, `amd64-test.log` | 3.2 | `go test` output per architecture |
| `arm64-race.log` | 3.2 | `go test -race` output, **with every detector report complete** |
| `arm64-startup.log` | 3.4 | startup output, including the `runtime.GOARCH` check |
| `arm64-bench.txt`, `amd64-bench.txt` | 3.2 | `go test -bench` output per architecture, if collected |

Raw files are verbatim tool output. Do not edit them, reformat them, or trim a stack trace — a report that cites `raw/arm64-race.log:142` is only useful if line 142 is still what the tool printed.
