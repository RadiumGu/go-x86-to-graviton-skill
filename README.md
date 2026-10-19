# Go x86-to-Graviton Migration Skill

An [Agent Skill](https://agentskills.io) that drives an AI coding agent through migrating a Go application from x86 to AWS Graviton (ARM64/aarch64) — static analysis, the fixes that are actually required, and validation on real arm64 hardware.

Built to the structure of the official [AWS Graviton Agent Skills](https://aws.github.io/graviton/tools/skills/), which ship skills for Java, Python and .NET but **not** Go.

中文使用说明：[docs/USAGE.zh-CN.md](docs/USAGE.zh-CN.md)

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

So `go test -race ./...` **on real arm64 hardware** is the highest-value single check in this skill, it is a mandatory exit criterion, and it has no equivalent in the Java or Python Graviton skills.

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
- report a `PASS` for a check that ran only under cross-compilation or emulation

---

## Install

The skill lives at the **root of this repository**, so the repository URL is the skill URL.

### Kiro

Open the **Agent Steering & Skills** panel → **+** → **Import a skill** → **GitHub**, and paste:

```
https://github.com/RadiumGu/go-x86-to-graviton-skill
```

Kiro reads `POWER.md`.

### Cursor

**Settings** (`Cmd+Shift+J` / `Ctrl+Shift+J`) → **Rules** → **Add Rule** → **Remote Rule (GitHub)**, and paste the same URL.

### Claude Code

```bash
git clone --depth 1 https://github.com/RadiumGu/go-x86-to-graviton-skill.git \
    /tmp/go-graviton-skill && \
  mkdir -p ~/.claude/skills/go-x86-to-graviton && \
  cp -r /tmp/go-graviton-skill/{SKILL.md,POWER.md,summaries.md,phases,document_references,scripts} \
        ~/.claude/skills/go-x86-to-graviton/ && \
  rm -rf /tmp/go-graviton-skill
```

### GitHub Copilot / VS Code (project-level)

```bash
git clone --depth 1 https://github.com/RadiumGu/go-x86-to-graviton-skill.git \
    /tmp/go-graviton-skill && \
  mkdir -p .github/skills/go-x86-to-graviton && \
  cp -r /tmp/go-graviton-skill/{SKILL.md,POWER.md,summaries.md,phases,document_references,scripts} \
        .github/skills/go-x86-to-graviton/ && \
  rm -rf /tmp/go-graviton-skill
```

### OpenAI Codex

```bash
# ~/.codex/skills/go-x86-to-graviton
```

### Windsurf

```bash
# .windsurf/skills/go-x86-to-graviton
```

### Goose

```bash
# ~/.config/goose/skills/go-x86-to-graviton
```

### Any Agent Skills platform (project-level, portable)

```bash
git clone --depth 1 https://github.com/RadiumGu/go-x86-to-graviton-skill.git \
    /tmp/go-graviton-skill && \
  mkdir -p .agents/skills/go-x86-to-graviton && \
  cp -r /tmp/go-graviton-skill/{SKILL.md,POWER.md,summaries.md,phases,document_references,scripts} \
        .agents/skills/go-x86-to-graviton/ && \
  rm -rf /tmp/go-graviton-skill
```

`.agents/skills/` is the cross-platform standard path and is read by every Agent Skills-compatible platform.

Replace the destination path in the Claude Code block to install for Codex, Windsurf, Goose or Roo Code (`.roo/skills/`); the copy itself is identical.

---

## Quick start

Install the skill, then in your agent, from the project root:

```
Migrate this Go service to AWS Graviton using the go-x86-to-graviton skill.
I have a c7g.xlarge running Amazon Linux 2023 available at graviton-ci for validation.
```

Naming the arm64 environment in the first message matters more than anything else you can say: without it, exit criteria 2 and 8–13 come back `NOT RUN` and the migration ships unvalidated.

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

Those four fields change the outcome more than anything else in the file. Configuration steers *how* the transformation runs — it cannot widen scope, cannot change the Go version except through `go.toolchain_bump`, and **cannot waive an exit criterion**, including the arm64 race run.

Full field reference: [`document_references/skill-configuration.md`](document_references/skill-configuration.md).

---

## Helper scripts

Both are stdlib-and-coreutils only, bash 3.2 compatible, and usable on their own without an agent.

### `scripts/go_arch_scan.sh` — read-only static scan

Covers the deterministic parts of Phase 1. **Never writes inside the scanned tree** and never runs the project's build.

```bash
./scripts/go_arch_scan.sh /path/to/your/go/project
./scripts/go_arch_scan.sh . > graviton-validation/raw/go-arch-scan.txt
```

Exit `0` clean, `1` findings, `2` not a Go project. Output lines are prefixed `OK`, `CHECK` or `FINDING`; a `CHECK` is a lead, not a verdict.

Without the Go toolchain it degrades to a grep-only mode in which every verdict is `CHECK`. With the toolchain it uses `go list` as the fact base and runs both Shape C detection passes.

### `scripts/arm64_validate.sh` — Phase 3 matrix

Runs cross-build, native build, `go vet` diff, `go test`, `go test -race`, and the binary architecture check, writing each log under `graviton-validation/raw/` with the canonical name the reports cite.

```bash
./scripts/arm64_validate.sh . \
  --cgo 1 \
  --tags 'netgo,osusergo' \
  --count 5 \
  --skip 'TestPostgres|TestS3' \
  --build-cmd 'make release'
```

It detects whether it is on arm64 hardware and reports every check it cannot measure as `NOT RUN` rather than `PASS` — including the race criterion, which it refuses to satisfy under emulation. On a race report it also runs the x86 baseline, because that comparison is what decides whether the finding is "this project has never run `-race`" or "arm64's weak memory model is what made it observable".

### `scripts/sync_power.sh` — keep the two entry points identical

```bash
./scripts/sync_power.sh     # regenerates POWER.md from SKILL.md
```

---

## Tests and CI

```bash
bash tests/run_tests.sh      # 31 assertions, no Go toolchain required
./scripts/sync_power.sh      # after editing SKILL.md
```

`tests/fixtures/broken/` carries one instance of every detectable defect plus two that
must **not** be reported (a correct `xx-go` Dockerfile, and a `.s` file whose constraint
sits at line 8). `tests/fixtures/clean/` must come back with zero findings.
`tests/memory-model/` is the litmus test and the race fixture.

[`.github/workflows/skill-ci.yml`](.github/workflows/skill-ci.yml) runs all of it on x86,
arm64 and macOS, scans `klauspost/compress` end to end, and re-measures the memory-model
result on both architectures.

To gate your **own** Go project, copy
[`examples/ci/graviton-gate.yml`](examples/ci/graviton-gate.yml) into
`.github/workflows/`. Set `DEPLOY_CGO_ENABLED` and `DEPLOY_BUILD_TAGS` to match your
deployment, and flip `SCAN_STRICT` to `1` once the repo is clean.

## Output

The transformation writes into `graviton-validation/` in your project:

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

### Regression tests

[`tests/run_tests.sh`](tests/run_tests.sh), 31 assertions, all passing. Each one pins a
specific output line, and each exists because that defect shipped. Run in CI on
`ubuntu-24.04`, `ubuntu-24.04-arm` and `macos-14` (the bash 3.2 floor), with shellcheck.

### Still not verified

- the cgo Route 2 / 3 / 4 resolution commands against live distro indexes and module
  caches. containerd's two cgo packages (`miekg/pkcs11` via `-ldl`,
  `containerd/btrfs/v2`) were detected and classified, but their aarch64 libraries were
  not sourced and built
- container and deployment-descriptor validation (Phase 3.3), including the in-image
  native-file scan
- `go.work` workspaces
- `arm64_validate.sh`'s race branch firing on a real `WARNING: DATA RACE` in a project's
  own suite (it was exercised on the memory-model fixture, not through the script)

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

## License

[Apache-2.0](LICENSE). The folder structure and file conventions follow the [AWS Graviton Agent Skills](https://github.com/aws/aws-graviton-getting-started/tree/main/tools/skills) layout; all content here is original.

## References

- [AWS Graviton Technical Guide](https://github.com/aws/aws-graviton-getting-started)
- [AWS Graviton Agent Skills](https://aws.github.io/graviton/tools/skills/) — Java, Python, .NET
- [Agent Skills specification](https://agentskills.io/specification)
- [Go memory model](https://go.dev/ref/mem)
- [Go specification: floating-point operators](https://go.dev/ref/spec#Floating_point_operators) — the FMA fusion allowance
- [Go build constraints](https://pkg.go.dev/cmd/go#hdr-Build_constraints)
- [AWS Graviton performance testing](https://docs.aws.amazon.com/whitepapers/latest/aws-graviton-performance-testing/other-considerations.html) — every vCPU is a physical core
- [Arm MCP Server](https://github.com/arm/mcp) — complementary: language-agnostic arm64 scanning tools over MCP
