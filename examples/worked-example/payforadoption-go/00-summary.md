# ARM64 Compatibility Validation — Summary

> This is a **real, complete run** of all three phases, not an illustration. The subject
> is `PetAdoptions/payforadoption-go` from `RadiumGu/one-observability-demo` — a Go
> service deployed on arm64 EKS. Every figure below came from a command whose output is
> in `raw/`. Reproduce it with the two scripts named at the bottom.

## Headline

**Migrated, with one open item and nothing to change in the code.** The module was
already arm64-ready: pure Go, no architecture-constrained files, and a Dockerfile that
hardcodes `GOARCH=arm64` deliberately. `go.mod` and `go.sum` are byte-identical before
and after.

```
Build:  PASS (native, c7g.2xlarge / Amazon Linux 2023, incl. the project's own release command)
Vet:    PASS (arm64 vs amd64 identical; 1 finding, PRE-EXISTING - see Out of Scope)
Tests:  PASS (2 packages with tests)
Race:   PASS (no race observed in 5 runs)        <- but see Remaining Concerns
cgo:    none (3 CgoFiles entries, all standard library)
Deps:   go.mod / go.sum unchanged
```

The one thing a human must decide: **this project has never run `go test -race`.** The
suite passing is therefore not evidence that it is race-free, and on Graviton a race is a
22–38% event rather than the 0-in-1.2e9-samples it is on x86 (measured; see the repo
README). Adding `-race` to the test command is the whole of Phase 2 here.

## Project Overview

| | |
|---|---|
| Module | `petadoptions` (`PetAdoptions/payforadoption-go`) |
| Deployed binary | `petadoptions` (one `main` package) |
| Resolved packages | **575** for linux/arm64, 576 for linux/amd64 |
| Non-stdlib packages | identical set on both architectures |
| Direct dependencies | 79 |
| Go files / test files | 20 / 5 |
| Go version (sources) | `go.mod` says `go 1.25.0`; the Dockerfile builder is `golang:1.25`; **this run used go1.27.2** |
| Build system (release path) | `docker build` → the Dockerfile's own `go build` line |
| Deployment | arm64 EKS; runtime image `alpine:3.22.1`, non-root, `EXPOSE 80` |
| Target | linux/arm64, musl (alpine), 4 KB pages |
| `CGO_ENABLED` (deployment) | `0`, set explicitly on the Dockerfile's build line |
| vendor / workspace | neither |

### Why the package counts differ, and why that is not a finding

amd64 resolves one package more than arm64: `vendor/golang.org/x/sys/cpu`, the standard
library's own vendored copy, which the amd64 crypto packages pull in for CPU feature
detection and the arm64 ones reach by another path. The **non-stdlib** set is identical
on both architectures, which is the comparison that carries information.

### Why the cgo count is zero despite three `CgoFiles` entries

`raw/go-list-deps-arm64.json` contains three packages with `CgoFiles`, and all three are
standard library: `runtime/cgo` (`cgo.go`), `net` (five `cgo_*.go` files) and `os/user`
(`cgo_lookup_cgo.go`, `getgrouplist_unix.go`). They appear because the capture is taken
with `CGO_ENABLED=1` on purpose — with cgo off, `go list` moves cgo files into
`IgnoredGoFiles` and a cgo-heavy project looks pure. The project itself uses no cgo.

## Exit Criteria

| # | Criterion | Verdict | Environment / Evidence |
|---|---|---|---|
| 1 | `GOOS=linux GOARCH=arm64 go build ./...` | PASS | `raw/arm64-crossbuild.log` |
| 2 | native arm64 build, deployment `CGO_ENABLED=0` | PASS | `raw/arm64-build.log`, c7g.2xlarge / AL2023 |
| 2b | **the project's own release command** | PASS | `raw/arm64-release-build.log` — `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -a -installsuffix cgo -o app .` |
| 3 | cgo C libraries aarch64 | N/A | no project cgo (`02`) |
| 4 | constrained files have an arm64 or generic path | N/A | **0** architecture-suffixed source files (`03`) |
| 5 | `go vet` arm64 vs amd64 | PASS | `raw/{arm64,amd64}-vet.log`, byte-identical — one finding, present on **both** architectures, so `PRE-EXISTING` not `ARM64`. Both runs are static, so this needed no arm64 host |
| 6 | container arm64, no x86 natives | NOT RUN | no container runtime in this environment (`07`) |
| 7 | `go.mod`/`go.sum` unchanged or cited | PASS | unchanged |
| 8 | `go test ./...` on arm64 | PASS | `raw/arm64-test.log`: `ok petadoptions`, `ok petadoptions/payforadoption` |
| 9 | `go test -race`, no data race | PASS | `raw/arm64-race.log`, 5 runs on c7g.2xlarge. **x86 baseline NOT RUN on this host** |
| 10 | failures classified | N/A | no failures |
| 11 | no ARM64-related test failures | PASS | `07` |
| 12 | starts on arm64, `runtime.GOARCH` is `arm64` | NOT RUN | needs the service's dependencies (DynamoDB, RDS, SSM) |
| 13 | binary is aarch64; `ldd` resolves aarch64 | PASS | `ELF 64-bit LSB executable, ARM aarch64, statically linked`; `ldd` → `not a dynamic executable` |
| 14 | Go version unchanged | PASS | `01` |
| 15 | canonical report filenames | PASS | this folder |

## Phase 1 Findings

One finding and one check, from `raw/go-arch-scan.txt`:

| # | Class | Finding | Verdict |
|---|---|---|---|
| 1 | behavioral | No `go test -race` anywhere in the build or CI configuration | **FINDING** — the weak-memory-order risk was unmeasured until this run |
| 2 | documentation | `benchmark/README.md:46` documents `docker buildx build -t drill-payforadoption . --platform=linux/amd64` | CHECK — a README for a *different* image (a load-test harness), not a build-stage defect |

Everything else came back clean, and the clean results are the substance of this report:

- **0** Shape C packages, reachable or latent (both `go list -deps` and the per-directory sweep)
- **0** architecture-suffixed source files, so no Shape A/B/C classification to make at all
- **0** committed native artifacts, **0** x86-hardcoded download URLs
- the Dockerfile **sets `GOARCH` for the target explicitly** — see below

### The Dockerfile is correct, and this skill accused it before it was fixed

`Dockerfile` line 16:

```dockerfile
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -a -installsuffix cgo -o app .
```

It hardcodes `arm64` rather than deriving it from `$TARGETARCH`, and the comment above it
explains why: a bare `docker build` then produces the wrong architecture *loudly* instead
of shipping an amd64 image that only fails on EKS. That is the most Graviton-ready form
there is.

An earlier version of the scanner reported it as defective, for two compounding reasons —
a `#` comment on line 14 mentions `docker buildx build --platform linux/arm64`, which the
raw grep counted as a `--platform` usage; and the `GOARCH` check accepted only
`GOARCH=$TARGETARCH`, not a literal. Both are fixed, and `tests/fixtures/broken/Dockerfile.literal`
pins the behaviour.

## Phase 2 Changes

**None applied to the code.** `go.mod`, `go.sum` and every source file are unchanged.
That is the correct outcome for this module and is the headline result, not a gap.

The one in-scope change is a CI addition rather than a code edit — add `-race` to the
test command, which is the architecture-only CI change Phase 2.4 permits:

```yaml
- run: go test ./...
- run: CGO_ENABLED=1 go test -race ./...   # new; CGO_ENABLED=1 is for the detector only
```

`CGO_ENABLED=1` there affects the **test** binary only; the shipped binary keeps the
Dockerfile's `CGO_ENABLED=0`. Copy `examples/ci/graviton-gate.yml` for the full gate.

## Recommendations Recorded (Not Applied)

See `06-runtime-configuration.md`. Nothing from it was applied, including `GOARM64`.

## Remaining Concerns

1. **The race result is one-sided.** `-race` passed in 5 runs on arm64, but the x86
   baseline did not run on that host, so `ARM64` and `PRE-EXISTING` cannot be told apart
   if a race ever appears. Run `arm64_validate.sh` on an x86 host too — the detector is
   architecture-independent, so that run is not a weaker check.
2. **"No race observed" is evidence, not proof.** The detector reports only what it
   observes, and 5 runs of a 2-package suite is a small sample. The durable fix is the CI
   matrix leg above, which turns this into a permanent gate.
3. **Criteria 6 and 12 are NOT RUN**, not PASS. The container was not built (no runtime
   available here) and the service was not started (it needs DynamoDB, RDS and SSM). Both
   belong to the deployment environment.
4. **The toolchain used here (go1.27.2) is newer than the deployment's (`golang:1.25`).**
   Every result above is qualified by that. Re-run on `golang:1.25` to remove the caveat.

## Observed, Out of Scope

- **`go vet` reports a real defect, on both architectures:**

  ```
  main.go:179:3: misuse of unbuffered os.Signal channel as argument to signal.Notify
  ```

  `signal.Notify` does not block when sending, so an unbuffered channel **drops signals**
  the receiver is not already waiting on — a `SIGTERM` arriving while the goroutine is
  busy is lost, and on EKS that turns a graceful shutdown into a kill after the
  termination grace period. The fix is one character: `make(chan os.Signal, 1)`.

  It is **out of scope here** because it is identical on amd64 and arm64 (that is what
  makes criterion 5 a PASS: no *arm64-only* findings), and folding an unrelated bug fix
  into a migration diff is exactly what `agent-scope-boundaries.md` forbids. It belongs
  in its own change — and it is worth making.

- `benchmark/README.md` documents an amd64-only build for the `drill-payforadoption`
  load-test image. Unrelated to this service's own migration.
- `go.mod` declares `go 1.25.0` while the Dockerfile builder is `golang:1.25`; they agree,
  and no change is needed. Recorded because the four version sources disagree in most
  projects and here they do not.

---

## Reproducing this

On a Graviton host with Go and git:

```bash
git clone --depth 1 https://github.com/RadiumGu/go-x86-to-graviton-skill.git /tmp/gvskill
cd /path/to/payforadoption-go
go mod download
/tmp/gvskill/scripts/go_arch_scan.sh .                     # Phase 1
/tmp/gvskill/scripts/arm64_validate.sh . --cgo 0 --count 5 \
  --build-cmd 'CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -a -installsuffix cgo -o /tmp/app .'
```

Measured on `c7g.2xlarge`, Amazon Linux 2023, go1.27.2, gcc 11.5.0, 8 vCPU.
