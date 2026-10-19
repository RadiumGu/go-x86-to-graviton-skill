---
name: go-x86-to-graviton
description: Validates Go application compatibility with AWS Graviton (ARM64/aarch64) architecture. Unlike Java or Python, Go module dependencies carry no per-architecture artifacts, so this transformation concentrates on the four places Go migrations actually break: cgo and the C libraries it links, amd64-only build constraints and assembly with no arm64 counterpart, non-Go artifacts (committed binaries, binaries downloaded by scripts or Dockerfiles, base images without an arm64 manifest), and behavioral differences that compile cleanly then fail at runtime - data races exposed by arm64's weak memory ordering, FMA-fused floating-point results, direct syscall numbers, and hardcoded page sizes. Performs static analysis, applies ARM64-required build and code fixes, documents Graviton runtime recommendations, and validates build, vet, race, tests and startup on ARM64. Supports Go modules, vendor/ trees, Go workspaces, Makefile and Bazel builds, GoReleaser, multi-stage Dockerfiles, Lambda provided.al2023, ECS and EKS. Use when migrating Go workloads from x86 to Graviton, validating ARM64 readiness, or diagnosing cgo, assembly or weak-memory-order failures on aarch64.
metadata:
  author: "RadiumGu"
  version: "1.0"
---

# Go Application AWS Graviton (ARM64) Compatibility Validation

Validate a Go application's readiness to run on AWS Graviton instances. This transformation determines whether the module builds for `GOARCH=arm64`, identifies every cgo and native-artifact dependency that needs an aarch64 build, finds amd64-only build constraints and assembly, locates the behavioral differences that compile silently and fail in production, updates only ARM64-blocking configuration and code, and tests on ARM64.

[summaries.md](summaries.md) indexes every file in this skill and when to read it: consult it for the full file map, or if you entered mid-skill without reading this file top to bottom.

## The Go Thesis (read this before anything else)

**Go is not Java and not Python. The dependency-availability question does not exist.**

A Go module dependency is source code. There is no per-architecture artifact to look for, no wheel, no classifier, no RID, no native asset directory. `go.mod` and `go.sum` are architecture-independent and in the overwhelming majority of migrations **neither file changes at all**. A dependency does not need updating because it is old.

An agent arriving with Java or Python habits will produce a report full of version bumps that have nothing to do with arm64. That is the single most likely failure mode of this transformation. See [document_references/agent-scope-boundaries.md](document_references/agent-scope-boundaries.md).

What actually breaks, in descending order of how often it blocks a migration:

| # | Class | Why it breaks | Fails at |
|---|-------|---------------|----------|
| 1 | **cgo** | `import "C"` makes the build depend on an aarch64 C toolchain and an aarch64 build of every C library linked | build time (loud) |
| 2 | **amd64-only build constraints and assembly** | a `//go:build amd64` file or `_amd64.s` with no arm64 or generic sibling | build time (loud) — or silently removes functionality if a weak fallback exists |
| 3 | **Non-Go artifacts** | committed `.so`/`.a`, tools downloaded with `_amd64` in the URL, base images with no arm64 manifest, `GOAMD64` in a Makefile | build or container-run time |
| 4 | **Behavioral differences** | data races exposed by arm64's weakly-ordered memory model, FMA-fused float results, direct `syscall.SYS_*` numbers, hardcoded 4096 page size, cgo-dependent DNS and user lookup | **run time, in production, intermittently** |

Class 4 is where Go migrations fail *after* they are declared successful. A pure-Go program that cross-compiles in two seconds can still deadlock on Graviton and never on x86, because x86-64 is Total Store Order and arm64 is weakly ordered: a program with a data race has no defined behavior on either, but only arm64 reliably shows you. **`go test -race` on arm64 is the highest-value single check in this entire skill** and has no equivalent in the Java or Python Graviton skills.

> **Verify with the toolchain, never with grep alone.** `go list -deps -json ./...` reports cgo usage, build-constrained files and the resolved dependency set as facts. grep is the fallback for when the toolchain cannot resolve (private modules, no network, Bazel-only builds) and every grep-derived verdict is labelled CHECK until the toolchain or a build confirms it. See [document_references/cgo-and-native-dependencies.md](document_references/cgo-and-native-dependencies.md).

## Scope Guardrails

**CRITICAL: Read [document_references/agent-scope-boundaries.md](document_references/agent-scope-boundaries.md) before starting.** It contains the decision tree for every finding and the Go-specific red flags that catch an agent importing Python or Java reflexes.

**In scope:** whether the module builds for `GOOS=linux GOARCH=arm64`; cgo usage and the aarch64 availability of every C library it links; `#cgo` directives carrying x86-only flags; build constraints and assembly files with no arm64 or generic path; `golang.org/x/sys/cpu` x86 feature gates without an arm64 or portable branch; committed and downloaded native artifacts; `GOAMD64` and hardcoded `GOARCH=amd64` in build scripts, Makefiles, GoReleaser configs, Dockerfiles and CI; base images and tool images without an arm64 manifest; deployment descriptors that pin x86 (Lambda `Architectures`, ECS `runtimePlatform`, K8s `nodeSelector`, ASG instance types, CDK/Terraform/CloudFormation equivalents); direct syscall numbers and page-size assumptions; CI changes that only add or switch an architecture; dependency updates that are **the only** route to an arm64 build path; ARM64 build, vet, race, test and startup validation; Graviton runtime recommendations (documented, never applied).

**Out of scope:** Go version changes (unless `go.toolchain_bump` allows a bump that is the only path to an arm64 build); dependency updates for any reason other than arm64 (modernization, security, features, deprecation warnings); replacing a cgo dependency with a pure-Go one unless the user confirms it; module path or package reorganization; base image family changes (alpine↔distroless↔Amazon Linux) unless the current family has no arm64 image at all; linter adoption; `go fmt`/`goimports` sweeps; code refactoring; performance optimization beyond documented recommendations; `.gitignore`/`.dockerignore` changes.

## Skill Configuration (Optional)

If a `skill-config.md` exists at the project root, read it before Phase 1 and apply its preferences (build system, module proxy, Go toolchain manager, test command, container registry and runtime, deployment and CI vocabulary) as overrides; if absent, use the neutral defaults in the phase docs. The configuration steers HOW the transformation runs but cannot widen scope: `agent-scope-boundaries.md` still binds, and the project's declared Go version stays unchanged unless `go.toolchain_bump` allows a bump. See [document_references/skill-configuration.md](document_references/skill-configuration.md) for the fields and [document_references/skill-config.template.md](document_references/skill-config.template.md) for a file to start from. Record any applied overrides in `01-project-assessment.md`.

## Entry Criteria

1. Go application currently running on x86 architecture
2. Source code and build scripts available
3. Current Go version documented (Phase 1.1 records where it was read from: `go.mod` `go`/`toolchain` directives, the Dockerfile builder image, CI setup-go, or `go version`)
4. Build configuration available: `go.mod`, `go.sum`, `vendor/modules.txt` if vendored, `go.work` if a workspace, plus Makefile, `.goreleaser.yaml`, `BUILD.bazel`, Dockerfiles, CI workflows and deployment descriptors as present
5. ARM64 build/test environment access (Graviton EC2, Apple Silicon, GitHub `ubuntu-24.04-arm` runner, or an arm64 container). **Pure-Go cross-compilation from x86 proves the build; it does not prove the behavior.** Class-4 findings require real arm64 execution — emulation under QEMU runs the code but reorders memory like the host in some configurations and is not evidence for the race check
6. Complete dependency set resolvable: either network access to the module proxy, a warm module cache, or a committed `vendor/` tree
7. Existing test suite
8. Tools the commands call: `git`, `go` (the project's version), `file`, `grep`, `awk`, `curl`, and a container runtime (Phase 1.4 image check and Phase 3 container validation). A C cross-compiler (`gcc-aarch64-linux-gnu`) only if cgo is present and you cross-compile rather than build natively

## Transformation Workflow

Copy this checklist into your response and check off each step:

```
ARM64 migration progress:
- [ ] Baseline commit; `graviton-validation/raw/` created; `skill-config.md` read if present
- [ ] 1.1 Build system, Go version, module/workspace/vendor layout, deployment type, target OS/libc/page size (01, raw/)
- [ ] 1.2 cgo inventory: every package with CgoFiles, every C library linked, aarch64 status per library (02)
- [ ] 1.3 Build constraints and assembly: amd64-only files with no arm64 or generic sibling, in the module AND in vendor/ (03)
- [ ] 1.4 Non-Go artifacts: committed binaries by content, downloaded tools, base and tool images, GOAMD64, deployment descriptors (04)
- [ ] 1.5 Behavioral scan: x86 CPU feature gates, direct syscall numbers, page size, FMA-sensitive float, cgo-dependent net/user, atomics (05)
- [ ] 1.6 Go version recorded with its support status and arm64-relevant floors, not changed (01)
- [ ] 2.1 cgo resolution: aarch64 C libraries sourced or built, #cgo directives made per-arch (02)
- [ ] 2.2 Build constraints and assembly: arm64 or generic path added or the amd64 gate relaxed (03)
- [ ] 2.3 Native artifacts re-sourced for arm64; download URLs and image references made arch-aware (04)
- [ ] 2.4 Build config: GOAMD64 removed or paired, Dockerfiles cross-compile on $BUILDPLATFORM for $TARGETARCH, GoReleaser/Makefile/CI/deployment arch settings updated (04)
- [ ] 2.5 Behavioral fixes: portable branches for CPU gates, named syscalls, os.Getpagesize(), forced float rounding where a test depends on it (05)
- [ ] 2.6 Runtime recommendations documented, not applied (06)
- [ ] 3.0-3.1 ARM64 build and `go vet`; failures classified INFRA / ARM64 / PRE-EXISTING (07)
- [ ] 3.2 `go test` on ARM64, then `go test -race` on ARM64 (the race run is mandatory and its own line) (07)
- [ ] 3.3 Container build and in-image architecture scan (07)
- [ ] 3.4 Startup on ARM64: runtime.GOARCH, linked libraries, DNS and user lookup, no SIGILL/SIGBUS (07)
- [ ] 00-summary.md: each exit criterion with where it ran
```

### Version Control Setup

Initialize git if not already present:

```bash
# Initialize if no git repo exists (local only, no remote required)
if [ ! -d ".git" ]; then
  git init
  git add -A
  git commit -m "Initial commit - baseline before ARM64 transformation"
fi
```

**Commit after each checklist step that changes files** with `git add -A && git commit -m "<message>"`, the message naming the step; skip the commit when a step changed nothing. Build outputs and module caches created for validation live outside the project tree (Phase 3.0), so `git add -A` never picks them up — with one exception: if the project vendors dependencies, Phase 2 may legitimately change `vendor/`, and that belongs in the commit.

### Documentation Setup

Before Phase 1, create the output structure. See [document_references/documentation-standards.md](document_references/documentation-standards.md) for required sections and templates.

```bash
mkdir -p graviton-validation/raw
```

Output files produced:

| File | Phase | Purpose |
|------|-------|---------|
| `01-project-assessment.md` | 1.1, 1.6 | Build system, module layout, Go version, deployment type, target OS/libc/page size |
| `02-cgo-report.md` | 1.2, 2.1 | Packages using cgo, C libraries linked, aarch64 status and resolution per library |
| `03-build-constraint-report.md` | 1.3, 2.2 | amd64-only constrained files and assembly, in the module and in `vendor/` |
| `04-artifact-and-build-config-findings.md` | 1.4, 2.3, 2.4 | Committed and downloaded binaries, images, `GOAMD64`, build scripts, deployment descriptors |
| `05-behavioral-findings.md` | 1.5, 2.5 | CPU feature gates, syscall numbers, page size, FMA-sensitive float, cgo-dependent `net`/`os/user`, atomics |
| `06-runtime-configuration.md` | 2.6 | Graviton runtime recommendations (documented, not applied) |
| `07-build-test-results.md` | 3.0-3.4 | Build, vet, test, **race**, container and startup results |
| `raw/go-list-deps.json` | 1.1, 1.2 | `go list -deps -json ./...` output: the authoritative dependency and cgo fact base |
| `raw/module-graph.txt` | 1.1 | `go mod graph` output |
| `raw/cgo-packages.txt` | 1.2 | One line per package with `CgoFiles`, with the C libraries it links |
| `raw/build-constraints.txt` | 1.3 | One line per architecture-constrained file, with its siblings |
| `raw/native-artifact-scan.txt` | 1.4 | Every committed native file found by content, with its architecture |
| `raw/image-platforms.txt` | 1.4 | One line per referenced image, with the platforms its registry publishes |
| `raw/arm64-build.log`, `raw/arm64-test.log`, `raw/arm64-race.log` | 3.1, 3.2 | Verbatim ARM64 build, test and race output |
| `00-summary.md` | End | Executive summary and exit criteria |

### Phase 1: Static Compatibility Analysis

Analyze the project without making changes. See [phases/phase1-static-analysis.md](phases/phase1-static-analysis.md) for detailed steps; per-build-system commands are in [document_references/module-management-mapping.md](document_references/module-management-mapping.md).

1. **1.1 Project Structure Analysis** — Build system detection (go build / Makefile / Bazel / GoReleaser / ko), module vs workspace vs vendored layout, multi-module detection, Go version detection with its source, deployment type, target OS, C library (glibc vs musl) and kernel page size, `go list -deps -json` capture
2. **1.2 cgo Inventory** — Every package in the resolved set with `CgoFiles`, every C library each one links (`#cgo LDFLAGS`, `pkg-config`, bundled `.a`), the aarch64 availability of each library, and `#cgo` directives carrying x86-only flags. Classify as BLOCKER / NEEDS AARCH64 BUILD / BUNDLED-OK / CGO-OPTIONAL / NOT CGO
3. **1.3 Build Constraint and Assembly Analysis** — Every file gated on an architecture, in the main module and in `vendor/`; the three shapes (amd64-only with no fallback = blocker, amd64-optimized with generic fallback = silent perf loss, amd64 with arm64 sibling = fine); `.s` assembly inventory; `//go:build` and legacy `// +build` both. Evidence standard: [document_references/build-constraints-and-assembly.md](document_references/build-constraints-and-assembly.md)
4. **1.4 Non-Go Artifact and Build Configuration Detection** — Committed native files judged by content; binaries downloaded by scripts, Dockerfiles and CI; base and tool image platforms from their registries; `GOAMD64`, hardcoded `GOARCH=amd64`, `-march`/`-mtune` flags; GoReleaser `goarch` lists; deployment descriptors that select x86, set or absent
5. **1.5 Behavioral Difference Scan** — `golang.org/x/sys/cpu` x86 gates, `runtime.GOARCH` comparisons, direct `syscall.SYS_*` numbers and numeric seccomp filters, hardcoded `4096`, float expressions whose tests assert exact equality, `CGO_ENABLED`-dependent `net`/`os/user` behavior, 64-bit atomics on struct fields, `unsafe` layout assumptions. Evidence standard: [document_references/behavioral-differences.md](document_references/behavioral-differences.md)
6. **1.6 Go Version Check** — Document version and live support status with the arm64-relevant floors (do NOT change it unless `go.toolchain_bump` allows; a change is one decision for the whole module)

### Phase 2: Compatibility Resolution

Apply fixes for ARM64-blocking issues only. See [phases/phase2-resolution.md](phases/phase2-resolution.md) for detailed steps.

1. **2.1 cgo Resolution** — Source or build each C library for aarch64, split `#cgo` directives per architecture (`#cgo amd64`, `#cgo arm64`), switch a bundled-static dependency to the version whose bundle includes arm64 or to its dynamic build tag, record substitutions as user decisions
2. **2.2 Build Constraint and Assembly Resolution** — Add the generic Go path, add an arm64 implementation, or relax the gate; never delete the amd64 fast path
3. **2.3 Native Artifact Resolution** — Re-source committed binaries for aarch64, make download URLs derive the architecture from `uname -m` or `$TARGETARCH`, replace single-arch image references with multi-arch ones
4. **2.4 Build Configuration Updates** — Remove or pair `GOAMD64`, convert Dockerfiles to the cross-compiling multi-stage pattern (`--platform=$BUILDPLATFORM` builder + `ARG TARGETARCH` + `GOARCH=$TARGETARCH`), add arm64 to GoReleaser and CI matrices, set the architecture in deployment descriptors
5. **2.5 Behavioral Fixes** — Add a portable or arm64 branch to each CPU feature gate, replace syscall numbers with named constants or `x/sys/unix`, replace hardcoded page sizes with `os.Getpagesize()`, add explicit `float64(...)` rounding or tolerances where a test depends on non-fused arithmetic. **Fix data races the race detector reports; never paper over one with a sleep, a channel reorder or `GOGC` tuning**
6. **2.6 Runtime Recommendations** — Document repo-sourced Graviton runtime settings with their evidence level; do not apply them

### Phase 3: ARM64 Validation & Testing

Build and test on ARM64. See [phases/phase3-validation.md](phases/phase3-validation.md) for detailed steps.

1. **3.0 Build Environment Prep** — ARM64 environment selection and what each one can prove, Go toolchain alignment (session-scoped only), cross-compile vs native-build decision
2. **3.1 Build and Vet Validation** — `GOOS=linux GOARCH=arm64 go build ./...`, then the native arm64 build, then `go vet ./...`; classify failures as INFRA/ARM64/PRE-EXISTING
3. **3.2 Functional and Race Testing** — `go test ./...` on arm64, then **`go test -race ./...` on arm64** as a separate mandatory step with its own log; classify failures; check results that change without failing
4. **3.3 Container Validation** — Build the arm64 image, then scan every native file inside it for the target architecture
5. **3.4 Startup Validation** — Verify the application starts on aarch64, `runtime.GOARCH` reports `arm64`, linked libraries are aarch64, DNS and user lookup behave, no `SIGILL`/`SIGBUS`/`exec format error`
6. **Write 00-summary.md** — Consolidate exit criteria using the template from documentation-standards.md

## Exit Criteria

A criterion that runs on ARM64 passes only on a Graviton host or the target itself, such as the arm64 Lambda function; one that ran only under emulation or by cross-compilation is NOT RUN (Phase 3, "What each environment can prove"). Cross-compilation from x86 satisfies criterion 1 and nothing else.

### Must Pass
1. `GOOS=linux GOARCH=arm64 go build ./...` succeeds
2. A native build on arm64 succeeds, with `CGO_ENABLED` set as the deployment sets it
3. Every cgo dependency links against an aarch64 C library, or is documented as a user decision
4. Every architecture-constrained file has an arm64 or generic path, in the module and in `vendor/`
5. `go vet ./...` on arm64 reports nothing new against the x86 baseline
6. Container images build for `linux/arm64` and contain no x86-64 native files (if containerized)
7. `go.mod` and `go.sum` unchanged, or every change traced to an arm64 blocker in `02`/`03`

### Test Criteria
8. `go test ./...` executes on ARM64
9. **`go test -race ./...` executes on ARM64 and reports no data race.** A race report is blocking: it is the class-4 finding this skill exists to catch
10. Failures classified: `INFRA` (non-blocking) / `ARM64` (blocking) / `PRE-EXISTING` (non-blocking)
11. No ARM64-related test failures

### Startup Criteria
12. Application starts on ARM64 without crashes; `runtime.GOARCH` reports `arm64`
13. If cgo is enabled, `ldd` on the binary resolves every library to an aarch64 file
14. Go version unchanged, or changed only through an approved `go.toolchain_bump`

### Documentation Criteria
15. All files in `graviton-validation/` using canonical names from documentation-standards.md

## Test Failure Handling

Infrastructure failures (missing database, services, credentials, network or module-proxy access, or one that fails the same way on the x86 baseline) are non-blocking: skip only those tests (`go test -run` with a narrowed pattern, or `-skip` on Go 1.20+), list them under CHECK Items, and take that run as the final build. A build that skips every test is never the final build.

ARM64 failures are blocking. Do not relax a build constraint to make a test pass, do not set `CGO_ENABLED=0` to get past a cgo link error unless the deployment also sets it, and do not drop `-race`; the failing build is the final build.

**Race detector failures are a distinct category and are always blocking.** A data race is a pre-existing defect in the code, not an arm64 defect — but arm64 is where it becomes a production incident, so it blocks this transformation. Classify it `ARM64` with a `PRE-EXISTING-ROOT-CAUSE` note. Record the full detector output in `raw/arm64-race.log`; it names both stacks and is the entire fix.

## User Responsibility (Post-Transformation)

- Performance benchmarking and load testing (`GOMAXPROCS`, instance-type selection, autoscaling thresholds). Every Graviton vCPU is a physical core with no SMT, so a same-vCPU-count Graviton instance has more physical cores than its x86 counterpart and concurrency assumptions calibrated on x86 are stale even when nothing fails
- Integration testing with external services
- CI/CD changes beyond architecture (credentials, deployment steps, triggers, tool versions), recommended in the vocabulary of `ci.system` when `skill-config.md` defines it; changes that only add or switch an architecture are applied in Phase 2.4 unless `ci.changes` is `recommend`
- Adopting any `06-runtime-configuration.md` recommendation marked Level B (measure before adopting), including `GOARM64`

## Notes

- **Cross-compiling is not validating.** `GOOS=linux GOARCH=arm64 go build ./...` passing on an x86 laptop is a genuine and valuable signal — for pure Go it is most of the build risk gone — but it executes nothing. Classes 1 (with cgo) and 4 are invisible to it
- **Emulation is not the race check.** QEMU under `docker run --platform linux/arm64` runs arm64 instructions, but it does not faithfully reproduce arm64's memory ordering: it is useful for build, link, import and startup checks and is not evidence for exit criterion 9. Run `-race` on real Graviton or Apple Silicon
- Monorepos and Go workspaces require analysis of every module and every `main` package; a workspace's `go.work` changes which module versions resolve, so capture `go list` from the workspace root as the deployment builds it
- A vendored project (`vendor/` present) builds from `vendor/` by default (`-mod=vendor` is implied when `vendor/modules.txt` matches `go.mod`). Phase 1.3's constraint scan **must** cover `vendor/` — that is where amd64-only assembly actually lives — and a Phase 2 dependency change requires `go mod vendor` to be re-run and committed
- Run the bash blocks with bash 3.2 or later. On macOS, where zsh is the default shell ([Apple](https://support.apple.com/en-us/102360)), start them with `bash`; on Windows, run the skill in a WSL 2 distribution ([Microsoft](https://learn.microsoft.com/en-us/windows/wsl/compare-versions)) with the project in the Linux file system
- The helper scripts in [scripts/](scripts/) are stdlib-and-coreutils only and are read-only: they never modify the project. They degrade to a grep-only mode when the Go toolchain is unavailable, and every verdict from that mode is CHECK, not PASS
