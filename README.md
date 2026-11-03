# Go x86-to-Graviton Migration Skill

**English** | [简体中文（使用手册）](docs/USAGE.zh-CN.md)

An [Agent Skill](https://agentskills.io) that drives an AI coding agent through migrating a Go application from x86 to AWS Graviton (ARM64/aarch64) — static analysis, the fixes that are actually required, and validation on real arm64 hardware.

Built to the structure of the official [AWS Graviton Agent Skills](https://aws.github.io/graviton/tools/skills/), which ship skills for Java, Python and .NET but **not** Go.

> **Disclaimer:** This is sample code for non-production, demonstration and learning purposes only. It is provided "as is" without warranty of any kind. Review and test it in your own environment before relying on it, and do not use it as-is for production workloads. You are responsible for validating the migration results against your own applications.

---

## Why Go needs its own skill rather than a copy of the Java one

The Java and Python Graviton skills spend most of their effort on a dependency **availability** question: does a `linux-aarch_64` classifier exist, does an `aarch64` wheel exist for this interpreter. For Go that question does not exist.

A Go module dependency is source code. `go.mod` records a version; `go.sum` records hashes of that source. Neither has an architecture dimension, and in the large majority of real migrations **both files are byte-identical before and after**.

Transplanting the Java/Python approach into Go produces pure noise — a report of version bumps that have nothing to do with arm64, burying the handful of changes that were actually required. This skill's first section exists to prevent exactly that, and its scope guardrails list it as the primary failure mode.

What actually breaks, in descending order of how often it blocks a migration:

| # | Class | Why | Fails at |
|---|---|---|---|
| 1 | **cgo** | `import "C"` makes the build depend on an aarch64 C toolchain and an aarch64 build of every linked C library | build time (loud) |
| 2 | **amd64-only build constraints and assembly** | a `//go:build amd64` file or `_amd64.s` with no arm64 or generic sibling | build time — or silently removes functionality if the fallback is a stub |
| 3 | **Non-Go artifacts** | committed `.so`/`.a`, tools downloaded with `_amd64` in the URL, base images with no arm64 manifest, `GOAMD64` in a Makefile | build or container-run time |
| 4 | **Behavioral differences** | data races exposed by arm64's weak memory ordering, FMA-fused float results, direct `syscall.SYS_*` numbers, hardcoded page sizes, `CGO_ENABLED`-driven resolver changes | **run time, in production, intermittently** |

Class 4 is where Go migrations fail *after* being declared successful. A pure-Go program that cross-compiles in two seconds can deadlock on Graviton and never on x86, because x86-64 is Total Store Order and arm64 is weakly ordered. A program with a data race has undefined behavior on both — but only arm64 reliably shows you.

So `go test -race ./...` is the highest-value single check in this skill and a mandatory exit criterion. It detects the same races on x86 as on arm64; real arm64 hardware adds the interleavings where those races become production incidents. It has no equivalent in the Java or Python Graviton skills.

---

## What it does

Three phases, each with its own document and its own report file:

**Phase 1 — static analysis.** Identify every build system and which one ships; resolve the dependency set for `GOARCH=arm64` with a two-pass `go list` capture; inventory cgo and classify each C library by the route it takes into the build; classify every architecture-constrained file into one of three shapes, in the module **and** in `vendor/`; find committed and downloaded native artifacts, single-arch images, and every place a build script or deployment descriptor selects x86; scan for the behavioral differences.

**Phase 2 — resolution.** Fix only what blocks arm64. Per-architecture `#cgo` directives, aarch64 C libraries, relaxed or widened build constraints, re-sourced binaries, the cross-compiling multi-stage Dockerfile pattern, architecture-aware GoReleaser/Makefile/CI/deployment settings, behavioral fixes. Graviton runtime recommendations are **documented, never applied**.

**Phase 3 — validation.** Cross-build, then the native arm64 build with the deployment's own release command, then `go vet` as a diff against the x86 baseline, then `go test`, then **`go test -race` as a separate mandatory step**, then the container's internal native-file scan, then startup. Every result names the environment it came from; a check that could not run is recorded `NOT RUN`, never `PASS`.

### What it deliberately does not do

- upgrade dependencies for any reason other than a named arm64 blocker
- change the Go version (unless a bump is the *only* route to an arm64 build, and the config permits it)
- change base image families, run linters, reformat code, or fix CVEs
- apply any runtime recommendation, including `GOARM64`
- replace a working cgo dependency with a pure-Go one on its own authority
- report a `PASS` for a check that ran only under cross-compilation or emulation (except `go vet` and the race detector, which do not depend on executing arm64 code)

---

## Install

The skill lives at the **root of this repository**, so the repository URL is the skill URL.

### Kiro

Open the **Agent Steering & Skills** panel → **+** → **Import a skill** → **GitHub**, and paste:

```
https://github.com/aws-samples/sample-go-x86-to-graviton-skill
```

Kiro reads `POWER.md`.

### Cursor

**Settings** (`Cmd+Shift+J` / `Ctrl+Shift+J`) → **Rules** → **Add Rule** → **Remote Rule (GitHub)**, and paste the same URL.

### User-level install (Claude Code, Codex, Goose): clone, then `git pull` to update

The skill directory is a plain clone of this repository, so updating it is one command and `git log` tells you what version you have:

```bash
git clone --depth 1 https://github.com/aws-samples/sample-go-x86-to-graviton-skill.git \
  ~/.claude/skills/go-x86-to-graviton

# update
git -C ~/.claude/skills/go-x86-to-graviton pull --ff-only
```

Same command for other agents, with their skills directory: `~/.codex/skills/go-x86-to-graviton`, `~/.config/goose/skills/go-x86-to-graviton`.

### Project-level install (`.agents/skills/`, GitHub Copilot, Windsurf, Roo Code): unpack, no nested repository

Do not clone into your project: a git repository inside your repository is an embedded repo that `git add` warns about and that your teammates do not get. Unpack a snapshot instead and commit it like any other file:

```bash
D=.agents/skills/go-x86-to-graviton     # or .github/skills/..., .windsurf/skills/..., .roo/skills/...
mkdir -p "$D" && curl -fsSL https://github.com/aws-samples/sample-go-x86-to-graviton-skill/archive/refs/heads/main.tar.gz \
  | tar -xz --strip-components=1 --exclude='*/tests' --exclude='*/examples' --exclude='*/.github' -C "$D"
```

To pin a version, replace `refs/heads/main` with a commit SHA. To update, delete `$D` and run the same command again. `.agents/skills/` is the cross-platform standard path and is read by every Agent Skills-compatible platform.

### Running the helper scripts after installing

The scripts run from wherever the skill was installed:

```bash
~/.claude/skills/go-x86-to-graviton/scripts/go_arch_scan.sh -h
```

---

## Quick start

Install the skill, then in your agent, from the project root:

```
Migrate this Go service to AWS Graviton using the go-x86-to-graviton skill.
I have a c7g.xlarge running Amazon Linux 2023 available at graviton-ci for validation.
```

Naming the arm64 environment in the first message matters more than anything else you can say: without it, exit criteria 2, 8 and 10–13 come back `NOT RUN` (5 and 9 still run on any host) and the migration ships unvalidated.

The agent writes everything into `graviton-validation/` in your project and commits after each step. Read `graviton-validation/00-summary.md` first.

### Requirements

| | |
|---|---|
| **Go toolchain** | the project's version. Without it the analysis degrades to a grep-only mode where every verdict is `CHECK` |
| **arm64 environment** | Graviton EC2, Apple Silicon, a GitHub `ubuntu-24.04-arm` runner, or an arm64 container. **Cross-compilation from x86 proves the build and nothing else** |
| **Container runtime** | only if the project is containerized (image platform checks, container validation) |
| **C compiler** | only if cgo is required — and also required for `go test -race`, even in a pure-Go project |
| **git** | the transformation commits per step so each change is individually revertible |

---

## Optional: `skill-config.md`

Drop a `skill-config.md` at your **project root** (not in the skill folder) to tell the agent your release build command, your build tags, your `CGO_ENABLED`, and where your arm64 host is. Copy [`document_references/skill-config.template.md`](document_references/skill-config.template.md) and delete what does not apply.

```yaml
language:
  go:
    build_system: make
    build_command: make release        # NOT `go build ./...` - that is developer-only
    build_tags: 'netgo,osusergo'       # without these the constraint analysis is wrong
    cgo_enabled: 0                     # as the DEPLOYMENT sets it
    arm64_environment: 'c7g.xlarge / Amazon Linux 2023, reachable as graviton-ci via SSH'
```

Those four fields change the outcome more than anything else in the file. Configuration steers *how* the transformation runs — it cannot widen scope, cannot change the Go version except through `go.toolchain_bump`, and **cannot waive an exit criterion**, including the race run.

Full field reference: [`document_references/skill-configuration.md`](document_references/skill-configuration.md).

---

## Helper scripts

Both need only bash 3.2+ and POSIX tools (no python), and are usable on their own without an agent. Flags take one or two dashes (`-tags x` or `--tags=x`), and an unknown flag is an error rather than being ignored.

### `scripts/go_arch_scan.sh` — read-only static scan

Covers the deterministic parts of Phase 1. **Never writes inside the scanned tree** and never runs the project's build.

```bash
./scripts/go_arch_scan.sh /path/to/your/go/project
./scripts/go_arch_scan.sh -tags netgo,osusergo .         # the DEPLOYMENT's build tags
./scripts/go_arch_scan.sh -o graviton-validation/raw .    # also writes raw/go-arch-scan.txt
./scripts/go_arch_scan.sh -json . | jq '.summary'         # one JSON document, for CI
```

| Flag | Meaning |
|---|---|
| `-tags LIST` | build tags as for `go build -tags`. Every tag the tree uses that the scan did not evaluate is named in a CHECK, because a Shape C blocker behind a tag is invisible without it |
| `-o FILE` | also write the report to FILE (a directory gets `go-arch-scan.txt`, or `.json` with `-json`) |
| `-json` | the same report as one JSON document: `summary`, `exit_code`, and one item per verdict with its details |
| `-strict` | advisories fail the scan too |

| Level | Meaning | Fails the scan |
|---|---|---|
| `FINDING` | arm64 migration work is required | yes (exit 1) |
| `ADVISORY` | not migration work: a gap in how the project is tested, such as never running `-race` | only with `-strict` |
| `CHECK` | a lead the scanner cannot decide | no |
| `OK` | checked and fine, recorded so nobody "fixes" it | no |

Exit `2` is a usage error, a directory that is not a Go project, or a scan that cannot run.

It judges directories the way the go command does: `testdata/` and directories starting with `_` or `.` are never packages, and every `go.mod` in the tree is resolved as its own module (a `go.work` root works, and a module the workspace does not list is resolved with `GOWORK=off`). With the toolchain it uses `go list -e` as the fact base and runs both Shape C detection passes in one batched call per architecture; without it, it degrades to a grep-only mode in which every verdict is `CHECK`.

### `scripts/arm64_validate.sh` — Phase 3 matrix

Runs cross-build, native build, `go vet` diff, `go test`, `go test -race`, and the binary architecture check, writing each log under `graviton-validation/raw/` with the canonical name the reports cite.

```bash
./scripts/arm64_validate.sh . \
  --cgo 1 \
  --tags 'netgo,osusergo' \
  --count 5 \
  --skip 'TestPostgres|TestS3' \
  --build-cmd 'make release' \
  --out graviton-validation/raw        # the default
```

The log directory is inside your project by default. Keep it out of git without touching your `.gitignore` with `echo 'graviton-validation/' >> .git/info/exclude`; the script warns when the directory would show up in `git status`.

It detects whether it is on arm64 (it cannot tell QEMU emulation from hardware, so qualify a `docker run --platform linux/arm64` run yourself) and runs `go vet` and the race check on every host, recording the architecture each ran on, because neither depends on executing arm64 code; every other check it cannot measure is `NOT RUN` rather than `PASS`. On a race report it also runs the x86 baseline, because that comparison is what decides whether the finding is "this project has never run `-race`" or "arm64's weak memory model is what made it observable".

### `scripts/sync_power.sh` — keep the two entry points identical

```bash
./scripts/sync_power.sh     # regenerates POWER.md from SKILL.md
```

---

## Tests and CI

```bash
bash tests/run_tests.sh      # runs without a Go toolchain too; the go-dependent sections SKIP
./scripts/sync_power.sh      # after editing SKILL.md
```

`tests/fixtures/broken/` carries one instance of every detectable defect plus two that
must **not** be reported (a correct `xx-go` Dockerfile, and a `.s` file whose constraint
sits at line 8). `tests/fixtures/clean/` must come back with zero findings.
`tests/fixtures/layout/` is laid out like a real repository: amd64-only files under
`testdata/`, `_scratch/` and `.cache/` that must **not** be reported, a nested module
with a real Shape C that must be, a Shape C that exists only under `-tags prod`, and a
`gotestsum -- -race` Makefile. `tests/fixtures/workspace/` is a `go.work` root with no
`go.mod` of its own, plus a module the workspace does not list.
`tests/memory-model/` is the litmus test and the race fixture.

[`.github/workflows/skill-ci.yml`](.github/workflows/skill-ci.yml) runs all of it on x86,
arm64 and macOS, scans `klauspost/compress` end to end, and re-measures the memory-model
result on both architectures.

To gate your **own** Go project, copy
[`examples/ci/graviton-gate.yml`](examples/ci/graviton-gate.yml) into
`.github/workflows/`. Set `DEPLOY_CGO_ENABLED` and `DEPLOY_BUILD_TAGS` to match your
deployment, and flip `SCAN_STRICT` to `1` once the repo is clean: from then on a new
FINDING fails the build.

## Output

The code changes land as one commit per step on a new branch, `graviton/arm64-migration`. The skill refuses to start on a dirty work tree, never runs `git add -A`, and does not push. The reports go into `graviton-validation/` in your project, which is excluded through `.git/info/exclude` (local, your `.gitignore` is untouched) so it never appears in the migration diff:

| File | Contents |
|---|---|
| `00-summary.md` | **Read this first.** Headline, exit criteria with the environment each ran in, changes made, changes deliberately not made, remaining concerns |
| `01-project-assessment.md` | Build systems, module layout, Go version with its four sources, target OS/libc/page size, `CGO_ENABLED`, build tags |
| `02-cgo-report.md` | cgo packages, each C library's route and aarch64 verdict with evidence |
| `03-build-constraint-report.md` | Architecture-constrained files by shape, reachable vs latent Shape C |
| `04-artifact-and-build-config-findings.md` | Committed and downloaded binaries, image platforms, build scripts, deployment descriptors, CI |
| `05-behavioral-findings.md` | Race results with full detector output, CPU gates, syscalls, page size, floats, `CGO_ENABLED` changes |
| `06-runtime-configuration.md` | Graviton recommendations with evidence levels — **none applied** |
| `07-build-test-results.md` | Build, vet, test, race, container and startup results, each with its environment |
| `raw/` | Verbatim tool output: `go list` captures, constraint sweeps, build/test/race logs, artifact and image scans |

---

## Skill files

See [`summaries.md`](summaries.md) for the canonical index of every file and when each one is read.

```
.
├── SKILL.md                    Entry point (Agent Skills format)
├── POWER.md                    Entry point (Kiro Powers format) - same body
├── summaries.md                Canonical file index
├── phases/
│   ├── phase1-static-analysis.md
│   ├── phase2-resolution.md
│   └── phase3-validation.md
├── document_references/
│   ├── agent-scope-boundaries.md          CRITICAL - read before starting
│   ├── cgo-and-native-dependencies.md
│   ├── build-constraints-and-assembly.md
│   ├── behavioral-differences.md
│   ├── module-management-mapping.md
│   ├── documentation-standards.md
│   ├── skill-configuration.md
│   └── skill-config.template.md
├── scripts/
│   ├── go_arch_scan.sh
│   ├── arm64_validate.sh
│   └── sync_power.sh
└── docs/
    └── USAGE.zh-CN.md
```

---

## Verification status

Everything below was executed, not inferred. Two dedicated EC2 instances in the same
subnet and availability zone, identical except for architecture: `c7g.2xlarge`
(Graviton3, arm64) and `c7i.2xlarge` (x86-64), both Amazon Linux 2023, Go 1.27.2,
gcc 11.5.0, 8 vCPU, 15 GB.

### The measurement the skill rests on

A message-passing litmus test - writer stores `data` then `flag`, reader loads `flag`
then `data`, no synchronization, the two variables on **separate cache lines**:

| | arm64 (Graviton3) | x86-64 |
|---|---|---|
| samples | 80.8M / 75.5M / 87.8M | 407.8M / 404.3M / 403.6M |
| reader saw flag ahead of data | **18,049,284 / 28,576,401 / 30,639,002** | **0 / 0 / 0** |
| rate | **22.3% / 37.9% / 34.9%** | **0 in 1.2e9 samples** |

Source: [`tests/memory-model/main.go`](tests/memory-model/main.go). Two methodology
errors were made and corrected on the way to this number, both documented in the file:
adjacent `int64` globals share a cache line and are ordered for free (a first version
measured **0 violations in 1.9e8 samples on arm64** purely because of that), and the
accesses must go through `//go:noinline` helpers or Go's compiler may keep a global in a
register across the loop.

### The correction that measurement forced

The **race detector is architecture-independent**. On a realistic bug (a lazily-warmed
cache published through a plain `bool`, [`tests/memory-model/cache/`](tests/memory-model/cache/)),
plain `go test` passed on **both** machines and `go test -race` reported **3 data races on
both**. An earlier version of this skill said emulation and x86 "do not count" for the
race criterion; that was wrong. Detection is instrumentation, not a hardware probe. What
arm64 adds is different interleaving, and the 22-38% manifestation rate above.

### All four cgo routes, executed

| Route | Subject | Result |
|---|---|---|
| 1 vendored C source | `mattn/go-sqlite3` | 6 C/H files in the module, **0** prebuilt archives, **0** files with unguarded x86 intrinsics. Built and ran: `sqlite=3.53.4`. No availability question exists, only a compiler requirement |
| 2 system library | a module linking `-lz` | Built and ran; CRC32 from system zlib matched Go's stdlib exactly (`2979356288` both), so the C library really executed. `ldd` resolved `libz.so.1` to an aarch64 file. The pkg-config form worked too. An unconditional `#cgo CFLAGS: -msse4.2` failed with `gcc: error: unrecognized command-line option '-msse4.2'` |
| 3 bundled archive | `confluent-kafka-go/v2` | v2.0.2 → v2.12.0 **all** bundle 7 archives including `librdkafka_glibc_linux_arm64.a` and `librdkafka_musl_linux_arm64.a`, so **no arm64 version floor exists** in the v2 line. `file` on the `.a` says `current ar archive` with no architecture; a extracted member says `ELF … ARM aarch64`. Built and ran: `librdkafka=0x20c00ff (2.12.0)`. `-tags dynamic` (the Route 3 → 2 conversion) failed with `Package rdkafka was not found in the pkg-config search path` — the conversion's cost, made concrete |
| 4 downloaded at build time | `grpc-health-probe`, `protoc` | The releases-API listing works. Downloaded and ran the arm64 binary (`0.4.41`); the wrong-arch one gave `cannot execute binary file: Exec format error`. **New finding: `protoc` uses a third naming vocabulary** — `protoc-36.2-linux-aarch_64.zip`, with an underscore, neither `arm64` nor `aarch64` |

Cross-compiling cgo, two corrections: `dnf install gcc-aarch64-linux-gnu` finds **no such
package on Amazon Linux 2023**, so an AL2023 build host cannot cross-compile cgo without
building a toolchain first; and without `CC` the failure is misleading —
`# runtime/cgo` / `gcc_arm64.S: Error: no such instruction: 'stp x29,x30,[sp,'`, which
reads like a Go runtime bug and is a missing cross-compiler.

A documented ambiguity that would have misrouted the fix: a package whose files are **all
cgo files** emits, under `CGO_ENABLED=0`, `build constraints exclude all Go files in
<dir>` — verbatim the Shape C message. Measured: `CGO_ENABLED=1` → `CgoFiles=[main.go]
Ignored=[]`; `CGO_ENABLED=0` → the Shape C error. For a *mixed* package the symptom is
different (`GoFiles=[plain.go] CgoFiles=[] Ignored=[only_cgo.go]`). The scan now resolves
the tree a third time with cgo off and routes such packages to Phase 2.1, not 2.2.

### A complete three-phase run on two of the author's own repositories

See [`examples/worked-example/payforadoption-go/`](examples/worked-example/payforadoption-go/)
for the report and the raw logs.

| | `sql-replay` | `payforadoption-go` |
|---|---|---|
| Shape | pure Go, 264 packages, 15 direct deps, no Dockerfile | pure Go, 575 packages, 79 direct deps, arm64 EKS service with its own Dockerfile |
| Phase 1 | **0 findings, 0 checks** | **1 finding** (no `go test -race` anywhere), 1 check (a README documents an amd64-only build of a different image) |
| Phase 2 | no changes | no code changes; `go.mod`/`go.sum` byte-identical |
| Phase 3 | build, vet, test and `-race` ×3 all PASS on arm64 | cross-build, native build, **the project's own release command**, vet, test and `-race` ×5 all PASS on arm64; binary is `ELF … ARM aarch64, statically linked` |

Three defects in the skill came out of that run, all now fixed and pinned by fixtures:
Dockerfile comments were treated as code, a literal `GOARCH=arm64` was not accepted as
setting the target (so the most Graviton-ready Dockerfile shape got accused), and
documentation was graded as a build file. Underneath the third was a shell bug worth
knowing: `grep -rn -- PATTERN . --include='*.md'` filters nothing, because `--` ends
option processing and `--include` becomes a path.

Two things the run established that the documents had not said:

- **A resolved package-count difference between architectures is normal.** amd64 resolves
  576 packages here and arm64 575; the one package is `vendor/golang.org/x/sys/cpu`, the
  standard library's own vendored copy. The **non-stdlib** set is identical, and that is
  the comparison that carries information. The scan now reports it that way.
- **`go vet` needs no arm64 host** — it is static analysis, so criterion 5 and its
  baseline run anywhere. The validator was gating it on the host architecture, the same
  mistake it had already been corrected for on the race check.

### Scanner, against four real repositories

Run on containerd (vendored, 1122 packages, 2 cgo packages), minio (1319 packages,
assembly-heavy, no vendor), confluent-kafka-go and go-sqlite3. Nine defects were found
in the scanner and fixed; the commit log names the repository that exposed each one. The
headline three:

- a failed `go list` capture printed `OK no reachable Shape C package` from an empty
  JSON file - an empty result read as an all-clear
- the in-file build-constraint check used `head -5`; containerd's vendored
  `goid_go1.4.s` carries its `// +build` at line 8 and `goid_go1.5.s` at line 18, both
  behind a license header, so both correct files were reported as defects
- a **false accusation** on containerd's `.github/workflows/release/Dockerfile`, which
  uses `tonistiigi/xx`: `xx-go --wrap` derives `GOARCH` from `$TARGETPLATFORM`, so the
  Dockerfile is correct and the skill's own case study had to be amended

After the fixes, containerd went from 10 findings / 14 checks to **2 findings / 10
checks**, and both remaining findings are real (4 x86-hardcoded download URLs, 3
hardcoded `GOARCH: amd64` in CI workflows).

### Scanner, reviewed against how Go projects are actually laid out

A second review asked whether the scanner judges a repository the way the go command
does. It did not. Five constructed cases, each now a fixture, showed two false findings
(amd64-only files under `testdata/` and `_scratch/`, which the go command never builds)
and three misses: an imported Shape C package in a nested module was reported `OK`, a
`go.work` root came back `RESOLUTION FAILED`, and a Shape C that exists only under the
release build tag was invisible because the scanner had no `-tags`. A
`gotestsum -- -race` Makefile was reported as never running the race detector, and that
report counted as a FINDING, so almost any repository exited 1.

After the rewrite (one batched `go list -e` per architecture and module, no python),
the same three repositories at the same commits give identical FINDING and CHECK lines
except for one new CHECK each naming the build tags the scan did not evaluate. Time
measured on an m8g.2xlarge:

| Repository | Before | After |
|---|---|---|
| containerd (vendored, 2 modules) | 69.3 s | 4.3 s |
| minio (6 modules) | 10.6 s | 3.1 s |
| klauspost/compress | 2.4 s | 1.1 s |

The new run also resolves the nested modules the old one never listed: containerd
1131 packages in 2 modules (was 1129), minio 1324 in 6 (was 1319).

### Regression tests

[`tests/run_tests.sh`](tests/run_tests.sh), 76 assertions with a Go toolchain and a C
compiler, all passing (52 without a Go toolchain, where the go-dependent sections SKIP). Each one pins a
specific output line, and each exists because that defect shipped. Run in CI on
`ubuntu-24.04`, `ubuntu-24.04-arm` and `macos-14` (the bash 3.2 floor), with shellcheck.

### Still not verified

- **container and deployment-descriptor validation (Phase 3.3)**, including the in-image
  native-file scan. No container runtime was available in the validation environment, so
  criterion 6 came back `NOT RUN` on both repositories
- **startup validation (criterion 12)** on a real service. `payforadoption-go` needs
  DynamoDB, RDS and SSM to start, so it was not run
- **`go.work` workspaces on a real repository**. The scanner's workspace handling is
  pinned by `tests/fixtures/workspace/` (a `go.work` root with no `go.mod`, plus a module
  the workspace does not list), but no real-world workspace repository has been scanned
- the **distro-index queries** for Route 2 (`apt-cache policy ...:arm64` via
  `ports.ubuntu.com`, `dnf --forcearch=aarch64`, `apk policy`). Route 2 itself was
  verified by building and running against a system library; the *availability lookup*
  commands for other distributions were not executed
- a Route 2 library that is genuinely **absent** for aarch64, which is the case that
  escalates to a user decision. Every library reached in this round had an aarch64 build

No dependency version floors are asserted anywhere in the skill. A recalled floor is a
wrong verdict waiting to happen, so the documents give the check to run instead.

## Contributing

Corrections welcome, particularly:

- a verdict the skill gets wrong on a real codebase
- a failure message not in the Phase 3.1 table
- a cgo module whose route is mis-described
- anything in the "Not verified" list above, verified

When editing `SKILL.md`, run `./scripts/sync_power.sh` so `POWER.md` cannot drift.

---

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to contribute, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for the project code of conduct. To report a potential security issue, follow the instructions in [CONTRIBUTING.md](CONTRIBUTING.md#security-issue-notifications) and do not open a public issue.

## License

[MIT-0](LICENSE). 

## References

- [AWS Graviton Technical Guide](https://github.com/aws/aws-graviton-getting-started)
- [AWS Graviton Agent Skills](https://aws.github.io/graviton/tools/skills/) — Java, Python, .NET
- [Agent Skills specification](https://agentskills.io/specification)
- [Go memory model](https://go.dev/ref/mem)
- [Go specification: floating-point operators](https://go.dev/ref/spec#Floating_point_operators) — the FMA fusion allowance
- [Go build constraints](https://pkg.go.dev/cmd/go#hdr-Build_constraints)
- [AWS Graviton performance testing](https://docs.aws.amazon.com/whitepapers/latest/aws-graviton-performance-testing/other-considerations.html) — every vCPU is a physical core
- [Arm MCP Server](https://github.com/arm/mcp) — complementary: language-agnostic arm64 scanning tools over MCP
