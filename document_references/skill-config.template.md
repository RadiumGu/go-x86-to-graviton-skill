# Skill Configuration — Template

Copy this file to **`skill-config.md` at your project root** (not into the skill folder) and fill in what applies. Delete what does not — every field has a working default, and a short file is better than a complete one.

Field meanings and precedence rules: [skill-configuration.md](skill-configuration.md).

Configuration steers HOW the transformation runs. It cannot widen scope, cannot change the declared Go version except through `toolchain_bump`, and cannot waive an exit criterion — including the arm64 race run.

---

## Shared

```yaml
shared:
  container:
    runtime: docker                 # docker | podman | nerdctl | finch
    registry: 123456789012.dkr.ecr.ap-northeast-1.amazonaws.com
    base_image_policy: preserve     # preserve (only value that is in scope)
    multiarch_tooling: buildx       # buildx | ko | goreleaser | none

  deployment:
    platform: ecs                   # ecs | eks | lambda | ec2 | apprunner | batch
    iac: terraform                  # cloudformation | sam | cdk | terraform | serverless | helm | kustomize | none
    target_os: amazonlinux:2023     # the RUNTIME image, not the builder
    oldest_graviton_generation: 3   # 2 | 3 | 4 | unknown  (bounds -march / GOARM64 advice)

  ci:
    system: github-actions          # github-actions | gitlab-ci | codebuild | jenkins | none
    changes: apply                  # apply | recommend
    arm64_runner: ubuntu-24.04-arm
```

## Go

```yaml
language:
  go:
    # The RELEASE build path - the one Phase 3 must validate.
    build_system: make              # go | make | goreleaser | bazel | ko
    build_command: make release
    test_command: go test ./...
    race_command: go test -race -count=3 ./...

    # Tests that need infrastructure this environment does not have.
    # Each still appears under CHECK Items with its INFRA evidence.
    test_skip_pattern: 'TestPostgres|TestS3Integration'

    # CRITICAL: the tags the deployment passes. Without these, the build-constraint
    # analysis examines a build that does not ship.
    build_tags: 'netgo,osusergo'

    # CRITICAL: as the deployment sets it. Decides Phase 3's build, and whether
    # `-race` can build at all (the race detector requires cgo).
    cgo_enabled: 0

    goproxy: https://proxy.example.internal,direct
    goprivate: github.com/myorg/*

    toolchain_manager: gotoolchain  # gotoolchain | goenv | asdf | mise | container
    toolchain_bump: false           # true ONLY permits a bump that is the sole route to an arm64 build

    vendor_mode: false
    workspace_root: .

    # The arm64 host available for validation. This field decides how much of the
    # skill can actually run: without it, exit criteria 2 and 8-13 are NOT RUN.
    arm64_environment: 'c7g.xlarge / Amazon Linux 2023, reachable as graviton-ci via SSH'
```

---

## Notes to the agent

Free-form. Anything here is read as context, not as permission — it cannot widen scope.

```
- The release artifact is the container image, not the binary. Validate the image.
- `make release` runs goreleaser under the hood; `go build ./...` is developer-only.
- internal/legacy is scheduled for deletion next quarter. Report findings there,
  do not fix them.
- We have never run `go test -race`. Expect findings.
```
