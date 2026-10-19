# Skill Configuration (Optional)

## Purpose

`skill-config.md` lets a team steer **how** the transformation runs — which build system is authoritative, which module proxy to use, which test command to run, which CI vocabulary to speak — without forking the skill. It is entirely optional: with no `skill-config.md`, the phase docs' neutral defaults apply and the transformation is complete.

## How it works

1. Place `skill-config.md` at the **project root** (the directory the agent runs in), not inside the skill
2. The agent reads it before Phase 1 and records every applied override in `01-project-assessment.md`
3. Start from [skill-config.template.md](skill-config.template.md)

The file is Markdown with YAML blocks. A missing field falls back to the default; an unrecognized field is ignored with a note in `01`.

## Precedence rules

Configuration steers HOW, never WHAT:

1. **`agent-scope-boundaries.md` always binds.** No configuration widens scope. There is no field that permits dependency modernization, a security sweep, a refactor, or applying a `06-runtime-configuration.md` recommendation
2. **The declared Go version does not change** unless `go.toolchain_bump` permits it, and then only when a bump is the *only* route to an arm64 build
3. **Exit criteria are not configurable.** In particular, `go test -race` on real arm64 hardware (criterion 9) cannot be waived by configuration. A project that cannot run it records `NOT RUN`; it does not get a pass
4. **An observed fact beats a configured one.** If `build.system: make` is configured and no Makefile exists, the detected reality wins and the discrepancy is recorded in `01`
5. **A configured command is run as given.** If `test.command` fails for a reason unrelated to the architecture, that is `INFRA` and is classified, not worked around by substituting a different command

## Section layout

Two groups. Shared fields apply to any language skill in this family; the `go` group is specific to this one.

```
shared:   container, deployment, ci
language: go
```

## Field reference

### `shared.container`

| Field | Default | Meaning |
|---|---|---|
| `runtime` | auto-detected (`docker`, `podman`, `nerdctl`, `finch`) | the container CLI to use |
| `registry` | none | registry prefix for image references in examples and recommendations |
| `base_image_policy` | `preserve` | `preserve` = never change a base image unless it has no arm64 manifest at all. No other value widens this |
| `multiarch_tooling` | `buildx` | `buildx`, `ko`, `goreleaser`, or `none` |

### `shared.deployment`

| Field | Default | Meaning |
|---|---|---|
| `platform` | auto-detected | `ecs`, `eks`, `lambda`, `ec2`, `apprunner`, `batch`, or several |
| `iac` | auto-detected | `cloudformation`, `sam`, `cdk`, `terraform`, `serverless`, `helm`, `kustomize`, `none`. Decides which descriptor Phase 2.4 edits and in whose vocabulary recommendations are written |
| `target_os` | auto-detected from the runtime image | e.g. `amazonlinux:2023`. Decides the libc and page-size grading |
| `oldest_graviton_generation` | unknown | `2`, `3`, `4`. Only used to bound an `-march`/`GOARM64` recommendation. `unknown` keeps every such item Level B |

### `shared.ci`

| Field | Default | Meaning |
|---|---|---|
| `system` | auto-detected | `github-actions`, `gitlab-ci`, `codebuild`, `jenkins`, `none`. Sets the vocabulary of CI recommendations |
| `changes` | `apply` | `apply` = Phase 2.4 applies architecture-only CI changes. `recommend` = write them into the report and change nothing |
| `arm64_runner` | auto | the runner label to use in a proposed matrix leg, e.g. `ubuntu-24.04-arm` or a self-hosted label |

### `language.go`

| Field | Default | Meaning |
|---|---|---|
| `build_system` | auto-detected | `go`, `make`, `goreleaser`, `bazel`, `ko`. The **release** path, which Phase 3 validates |
| `build_command` | `go build ./...` | the deployment's own build command. Phase 3.1 step 3 runs this |
| `test_command` | `go test ./...` | |
| `race_command` | `go test -race ./...` | |
| `test_skip_pattern` | none | a `-skip` regex for tests known to need infrastructure. Each one still appears under CHECK Items with its `INFRA` evidence |
| `build_tags` | none | tags the deployment passes. **The constraint analysis is wrong without these** |
| `cgo_enabled` | auto from `go env` and the build scripts | `0` or `1`, as the deployment sets it. Decides Phase 3's build and whether `-race` can build |
| `goproxy` | from `go env GOPROXY` | |
| `goprivate` | from `go env GOPRIVATE` | |
| `toolchain_manager` | auto | `gotoolchain`, `goenv`, `asdf`, `mise`, `container`. How Phase 3.0 switches Go versions, session-scoped |
| `toolchain_bump` | `false` | `true` permits a Go version change **only** when it is the sole route to an arm64 build. Any other reason remains out of scope |
| `vendor_mode` | auto from `vendor/modules.txt` | `true` forces `-mod=vendor` |
| `workspace_root` | auto from `go.work` | the directory every `go list`/`go build` runs from |
| `arm64_environment` | none | a description of the arm64 host available, e.g. `c7g.xlarge / AL2023 via SSH`. Recorded in `07`'s environment table; its absence means criteria 2 and 8-13 are likely `NOT RUN` |

## Authoring notes

- Keep it short. A 20-line `skill-config.md` naming the release build command, the build tags and the arm64 host is worth more than a 200-line one restating the defaults
- The two fields that most often change the outcome are `build_tags` (without them the constraint analysis examines a build that does not ship) and `cgo_enabled` (without it Phase 3 builds something the deployment does not)
- `arm64_environment` is the field that decides how much of this skill can actually run. Fill it in
- Do not use it to record findings. It is input to the transformation, not output; findings go in `graviton-validation/`
