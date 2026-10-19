# Build System Mapping

Detection markers and per-build-system commands. Read in Phase 1.1 to identify the build system, and whenever a later step needs that system's command.

**Detect every build system present, and establish which one ships.** A repo commonly has `go build` for developers, a Makefile for CI and GoReleaser for releases. The release path is the one this transformation must validate — a `go build ./...` that passes while `make release` fails is not a pass.

## Contents

- [Detection markers](#detection-markers)
- [Command table](#command-table)
- [go build / go test (the base path)](#go-build--go-test-the-base-path)
- [Modules, vendor and workspaces](#modules-vendor-and-workspaces)
- [Makefile](#makefile)
- [GoReleaser](#goreleaser)
- [Bazel with rules_go](#bazel-with-rules_go)
- [ko](#ko)
- [Docker and buildx](#docker-and-buildx)
- [AWS Lambda](#aws-lambda)
- [CI systems](#ci-systems)
- [Private module proxies](#private-module-proxies)

---

## Detection markers

| Build system | Markers |
|---|---|
| Go modules | `go.mod`, `go.sum` |
| Vendored modules | `vendor/modules.txt` |
| Go workspace | `go.work`, `go.work.sum` |
| Makefile | `Makefile`, `makefile`, `GNUmakefile`, `*.mk` |
| GoReleaser | `.goreleaser.yaml`, `.goreleaser.yml` |
| Bazel | `MODULE.bazel`, `WORKSPACE`, `BUILD.bazel`, `BUILD` |
| ko | `.ko.yaml`, or `ko build` in a script or CI job |
| Docker | `Dockerfile*`, `compose.yaml`, `docker-compose.yml` |
| Lambda (SAM) | `template.yaml` with `AWS::Serverless::Function`, `samconfig.toml` |
| Lambda (CDK) | `cdk.json` plus a `lambda.Function` or `GoFunction` construct |
| Lambda (Serverless Framework) | `serverless.yml` |
| Terraform | `*.tf` with `aws_lambda_function`, `aws_ecs_task_definition`, `aws_launch_template` |
| Kubernetes | `*.yaml` with `kind: Deployment`, Helm `Chart.yaml`, `kustomization.yaml` |
| GitHub Actions | `.github/workflows/*.yml` |
| GitLab CI | `.gitlab-ci.yml` |
| CodeBuild | `buildspec.yml`, `buildspec*.yaml` |
| Tool version managers | `.go-version` (goenv), `.tool-versions` (asdf, mise) |

```bash
ls -1 go.mod go.sum go.work vendor/modules.txt Makefile .goreleaser.yaml .goreleaser.yml \
      .ko.yaml MODULE.bazel WORKSPACE template.yaml samconfig.toml serverless.yml \
      cdk.json .go-version .tool-versions 2>/dev/null
find . -maxdepth 3 -name 'Dockerfile*' -o -maxdepth 3 -name 'buildspec*.y*ml' \
  -o -maxdepth 2 -name '*.tf' 2>/dev/null | grep -v vendor | head -20
ls -1 .github/workflows/ 2>/dev/null
```

---

## Command table

The command each phase needs, per build system. `$GOARCH_TARGET` is `arm64` throughout.

| Need | `go build` | Makefile | GoReleaser | Bazel | Docker |
|---|---|---|---|---|---|
| Resolved dep set | `go list -deps -json ./...` | same | same | `bazel query 'deps(//...)'` | run `go list` in the builder stage |
| Cross-build check | `GOOS=linux GOARCH=arm64 go build ./...` | read the target; usually wraps the same | `goreleaser build --single-target` with `GOARCH` | `--platforms=@rules_go//go/toolchain:linux_arm64` | `buildx build --platform linux/arm64` |
| Native build | `go build ./...` | `make build` | `goreleaser build --snapshot` | `bazel build //...` | same as above, on an arm64 builder |
| Test | `go test ./...` | `make test` | n/a | `bazel test //...` | a test stage, or run in the image |
| Race | `go test -race ./...` | `make test-race` if present, else direct | n/a | `bazel test --features=race //...` | run in the image |
| Vet | `go vet ./...` | `make vet`/`make lint` | n/a | `bazel run @rules_go//go -- vet ./...` | — |
| Vendor refresh | `go mod vendor` | `make vendor` | n/a | `bazel run //:gazelle-update-repos` | — |

---

## go build / go test (the base path)

```bash
# Phase 1.1 - resolved set, per architecture. Capture stderr; it holds the constraint errors.
GOOS=linux GOARCH=arm64 go list -deps -json ./... \
  > graviton-validation/raw/go-list-deps-arm64.json 2>graviton-validation/raw/go-list-deps-arm64.err
GOOS=linux GOARCH=amd64 go list -deps -json ./... \
  > graviton-validation/raw/go-list-deps-amd64.json 2>graviton-validation/raw/go-list-deps-amd64.err

# Which files a given package would compile, per architecture
GOOS=linux GOARCH=arm64 go list -f '{{.ImportPath}} GoFiles={{.GoFiles}} SFiles={{.SFiles}} Ignored={{.IgnoredGoFiles}}' ./internal/...

# Phase 3.1 - cross-build, then native
GOOS=linux GOARCH=arm64 go build ./...
go build -o "$GOBIN/" ./...

# Phase 3.2
go test ./...
go test -race ./...

# Available versions of a module (Phase 2.2 upgrades)
go list -m -versions github.com/example/dep

# Where a module's source is on disk (Phase 1.2 route detection)
go list -m -f '{{.Path}} {{.Version}} {{.Dir}}' github.com/example/dep
```

Useful environment facts to record in `01-project-assessment.md`:

```bash
go env GOVERSION GOARCH GOOS CGO_ENABLED CC GOFLAGS GOMODCACHE GOCACHE GOPROXY GOPRIVATE GOTOOLCHAIN
```

`GOFLAGS` deserves attention: a `GOFLAGS=-mod=vendor` or `GOFLAGS=-tags=foo` in the environment or in `go env -w` changes what every command above resolves, invisibly.

---

## Modules, vendor and workspaces

### Plain modules

`go.mod` and `go.sum` are architecture-independent. In most migrations neither changes. Add `-mod=mod` only when a step must deliberately touch them (Phase 2.2).

### Vendored (`vendor/modules.txt` present)

The build uses `vendor/` and ignores the proxy, automatically, when `modules.txt` is consistent with `go.mod`. Three consequences:

```bash
# 1. Phase 1.3's constraint scan MUST cover vendor/ - that is where amd64-only assembly lives
grep -rn --include='*.go' --include='*.s' -E '^//[[:space:]]*(go:build|\+build)[^\n]*amd64' vendor/ | head

# 2. A dependency change requires re-vendoring, or the old code still ships
go get github.com/example/dep@v1.9.0 && go mod tidy && go mod vendor
git add -A vendor go.mod go.sum

# 3. Never hand-edit vendor/. Verify consistency instead:
go mod verify
go mod vendor && git diff --stat vendor/    # a non-empty diff means vendor/ was stale or edited
```

A non-empty `git diff vendor/` after a fresh `go mod vendor`, before any Phase 2 change, is itself a finding worth reporting: someone has hand-edited the vendor tree and the next `go mod vendor` in CI will revert it.

### Workspaces (`go.work` present)

`go.work` changes which module versions resolve, so every `go list`, `go build` and `go test` must run from the workspace root — the directory the deployment builds from. Running from a member module resolves a different version set and analyses a tree that does not ship.

```bash
go work edit -json | python3 -c 'import json,sys; d=json.load(sys.stdin); print([u["DiskPath"] for u in d.get("Use",[])])'
# Validate each member resolves for arm64
GOOS=linux GOARCH=arm64 go build ./... 2>&1 | tail
```

### Multi-module repos without a workspace

Each module is analysed separately: its own `go list` capture, its own reports section, its own build and test runs. Record which modules produce deployed binaries; a module with no `main` package still needs the constraint scan, because its code is compiled into the ones that do.

---

## Makefile

Read the targets rather than guessing them:

```bash
# Target names (GNU make 4.x)
make -qp 2>/dev/null | awk -F: '/^[a-zA-Z0-9][^$#\/\t=]*:([^=]|$)/ {print $1}' | sort -u | head -40
# or just
grep -nE '^[a-zA-Z0-9_.-]+:' Makefile | head -40

# Architecture pins and flags
grep -nE 'GOARCH|GOOS|GOAMD64|GOARM64|CGO_ENABLED|-tags|-ldflags|-gcflags|CC=' Makefile *.mk 2>/dev/null
```

The Phase 2.4 pattern for making a target architecture-aware without pinning either side:

```make
GOOS   ?= linux
GOARCH ?= $(shell go env GOARCH)

build:
	CGO_ENABLED=$(CGO_ENABLED) GOOS=$(GOOS) GOARCH=$(GOARCH) \
	  go build -trimpath -ldflags="-s -w" -o bin/app-$(GOOS)-$(GOARCH) ./cmd/app

build-all: ; $(MAKE) build GOARCH=amd64 && $(MAKE) build GOARCH=arm64
```

`?=` matters: it lets CI and the Dockerfile override the architecture without editing the Makefile, which is the whole point of the change.

---

## GoReleaser

```bash
grep -nE '^[[:space:]]*(goos|goarch|goamd64|goarm64|env|main|id):' .goreleaser.y*ml
grep -nE 'docker_manifests|dockers:|image_templates' .goreleaser.y*ml
goreleaser check 2>&1 | tail -5
```

Adding `arm64` to `goarch` is necessary and not sufficient. Without `docker_manifests`, consumers pulling the plain tag still get whichever single-architecture image was pushed last:

```yaml
builds:
  - id: app
    main: ./cmd/app
    env: [CGO_ENABLED=0]
    goos: [linux]
    goarch: [amd64, arm64]

dockers:
  - image_templates: ["{{ .Env.REGISTRY }}/app:{{ .Version }}-amd64"]
    use: buildx
    build_flag_templates: ["--platform=linux/amd64"]
    goarch: amd64
  - image_templates: ["{{ .Env.REGISTRY }}/app:{{ .Version }}-arm64"]
    use: buildx
    build_flag_templates: ["--platform=linux/arm64"]
    goarch: arm64

docker_manifests:
  - name_template: "{{ .Env.REGISTRY }}/app:{{ .Version }}"
    image_templates:
      - "{{ .Env.REGISTRY }}/app:{{ .Version }}-amd64"
      - "{{ .Env.REGISTRY }}/app:{{ .Version }}-arm64"
```

Validate locally without publishing:

```bash
goreleaser build --snapshot --clean
ls -1 dist/ && file -b dist/*linux_arm64*/app 2>/dev/null
```

If the project sets `goamd64:`, leave it — it is x86-only and inert elsewhere. Do **not** add `goarm64:`; that is a Level-B fleet decision (`06-runtime-configuration.md`).

---

## Bazel with `rules_go`

Bazel's dependency set comes from `MODULE.bazel`/`WORKSPACE` and the `BUILD` files, **not** from `go list`. A `go list` capture may miss the real set entirely, so take the resolved set from Bazel:

```bash
bazel query 'deps(//...)' --output=label 2>/dev/null | grep -E '^@|go_default_library' | sort -u | head -40
bazel query 'kind("go_binary", //...)' 2>/dev/null       # the deployed binaries
bazel query 'kind("cc_.*", deps(//...))' 2>/dev/null     # the C dependencies - the cgo question
```

Cross-build and test for arm64:

```bash
bazel build --platforms=@rules_go//go/toolchain:linux_arm64 //...
bazel test --features=race //...                          # native arm64 only
```

Two Bazel-specific findings:

- `--host_platform` / `--platforms` hardcoded to an x86 platform in `.bazelrc`
- a `go_binary` with `goarch = "amd64"` set in its rule, which overrides the command line

```bash
grep -nE 'platforms|host_platform|cpu=|goarch' .bazelrc 2>/dev/null
grep -rn 'goarch' --include='BUILD*' --include='*.bzl' . 2>/dev/null | head
```

When `gazelle` manages the `BUILD` files, a dependency change in Phase 2.2 needs `bazel run //:gazelle-update-repos` and `bazel run //:gazelle` afterwards, or the new version never reaches the build.

---

## ko

`ko` builds Go container images without a Dockerfile and is multi-arch by default — `--platform=all` covers `linux/amd64` and `linux/arm64`. Findings are narrower than with Docker:

```bash
cat .ko.yaml 2>/dev/null
grep -rn 'ko build\|ko apply\|KO_DEFAULTBASEIMAGE\|--platform' . \
  --include='Makefile' --include='*.sh' --include='*.yml' --include='*.yaml' --exclude-dir=.git 2>/dev/null
```

| Finding | Fix |
|---|---|
| `--platform=linux/amd64` passed explicitly | `--platform=linux/amd64,linux/arm64` or `--platform=all` |
| `defaultBaseImage` in `.ko.yaml` with no arm64 manifest | a multi-arch base, verified from the registry |
| cgo required | ko builds with `CGO_ENABLED=0` by default; a cgo project needs a different path entirely |

```bash
ko build --platform=linux/amd64,linux/arm64 --push=false ./cmd/app 2>&1 | tail -5
```

---

## Docker and buildx

The cross-compiling multi-stage pattern (Phase 2.4) is the target state. Validate it rather than trusting the manifest:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t myapp:multi --push .
docker buildx imagetools inspect myapp:multi | grep -iE 'platform|digest'

# The image's declared architecture
docker image inspect myapp:arm64 --format '{{.Architecture}}/{{.Os}}'

# The BINARY's architecture - the one that actually matters
docker create --name t myapp:arm64 >/dev/null
docker cp t:/app /tmp/a && file -b /tmp/a; docker rm -f t >/dev/null; rm -f /tmp/a
```

Builder setup, when the default builder cannot do multi-platform:

```bash
docker buildx create --name multi --driver docker-container --use 2>/dev/null
docker buildx inspect --bootstrap | grep -i platforms
# On an x86 host, register emulation so arm64 stages can RUN (not needed for the cross-compile pattern)
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

For a genuinely mixed build (an arm64 stage that must `RUN` arm64 code, e.g. a cgo build or an arm64 test stage), prefer a **native arm64 builder node** over emulation:

```bash
docker buildx create --name multi --node arm --platform linux/arm64 ssh://user@graviton-host
docker buildx create --name multi --append --node amd --platform linux/amd64
```

---

## AWS Lambda

Go on Lambda uses the `provided.al2023` custom runtime: the deployment artifact is a binary named `bootstrap`.

```bash
# The build: GOARCH is what makes it arm64; the name must be bootstrap
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
  go build -tags lambda.norpc -trimpath -ldflags="-s -w" -o bootstrap ./cmd/fn
zip fn.zip bootstrap
file -b bootstrap     # must report ARM aarch64
```

The architecture must be set in **two** places and both are required:

```yaml
# SAM / CloudFormation
Runtime: provided.al2023
Architectures: [arm64]       # absent => x86_64
Handler: bootstrap
```

```bash
# Verify the deployed function, which is the authoritative answer
aws lambda get-function-configuration --function-name my-fn \
  --query '{Arch:Architectures,Runtime:Runtime,Handler:Handler}' --no-cli-pager
```

| Platform | Field | Default when absent |
|---|---|---|
| SAM / CloudFormation | `Architectures: [arm64]` | `x86_64` |
| CDK (`lambda.Function`) | `architecture: lambda.Architecture.ARM_64` | `X86_64` |
| CDK (`GoFunction`, alpha) | `architecture:` plus `bundling` that sets `GOARCH` | `X86_64` |
| Terraform | `architectures = ["arm64"]` | `["x86_64"]` |
| Serverless Framework | `provider.architecture: arm64` | `x86_64` |

The CDK `GoFunction` case has a trap worth its own note: setting `architecture` without setting `GOARCH` in the bundling options produces an arm64 *function configuration* running an amd64 *binary*, which fails at the first invocation with a runtime error rather than at deploy time.

Lambda layers containing native code need the same treatment as any other native artifact — `file` on each library inside the layer zip (Phase 1.4).

---

## CI systems

| System | arm64 runner | Multi-arch images |
|---|---|---|
| GitHub Actions | `runs-on: ubuntu-24.04-arm` (also `ubuntu-22.04-arm`) | `docker/build-push-action` with `platforms:`, or a matrix of native runners |
| GitLab CI | a `saas-linux-*-arm64` or self-managed arm64 runner, selected by tag | `docker buildx` in the job |
| AWS CodeBuild | an `ARM_CONTAINER` environment type with an aarch64 image | `buildx` in `buildspec.yml` |
| Jenkins | an arm64 agent, selected by label | `buildx` in the pipeline |

```yaml
# GitHub Actions: the durable form of this skill's most important check
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        runner: [ubuntu-24.04, ubuntu-24.04-arm]
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod
          cache: true
      - run: go build ./...
      - run: go vet ./...
      - run: go test ./...
      - run: go test -race ./...
```

Adding the arm64 matrix leg turns a one-time migration finding into a permanent gate, and it is the single most valuable CI change in this transformation. Add it even when the current run is green.

Prefer native runners over `docker/setup-qemu-action`. QEMU works and is roughly an order of magnitude slower; for Go it is also unnecessary, because the cross-compiling Dockerfile pattern needs no emulation at all.

```bash
# Where the architecture is currently decided in CI
grep -rnE 'runs-on|platforms:|setup-qemu|buildx|GOARCH|ARM_CONTAINER|image:' \
  .github/workflows/ .gitlab-ci.yml buildspec*.y*ml 2>/dev/null | head -40
```

---

## Private module proxies

A private proxy or a vendored private module is **architecture-independent**, like any other Go dependency — but an unreachable one breaks the Phase 1.1 capture, and a failed capture is not an all-clear.

```bash
go env GOPROXY GOPRIVATE GONOSUMCHECK GONOSUMDB GOINSECURE GOFLAGS
grep -rn 'GOPRIVATE\|GOPROXY\|insteadOf' . --include='Dockerfile*' --include='Makefile' \
  --include='*.yml' --include='*.yaml' ~/.gitconfig 2>/dev/null | head
```

When a private module cannot be resolved:

1. use the committed `vendor/` tree if present — it contains the source and the scan works offline
2. otherwise mark that module's packages `CHECK` in `01` and `03`, state the reason, and continue. Do not report the tree as clean
3. record it in `00-summary.md` under Remaining Concerns

Do not disable checksum verification or set `GOFLAGS=-insecure` to get a capture. An unresolvable dependency is a `CHECK`, not a reason to weaken the build's integrity checks.
