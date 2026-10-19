# Worked example — `payforadoption-go`

A **real, complete run** of all three phases against
`PetAdoptions/payforadoption-go` from `RadiumGu/one-observability-demo`: a Go service
deployed on arm64 EKS, 79 direct dependencies, 575 resolved packages, its own Dockerfile
and release build command.

Measured on a `c7g.2xlarge`, Amazon Linux 2023, go1.27.2, gcc 11.5.0, 8 vCPU.

- [`00-summary.md`](00-summary.md) — the report a reviewer reads
- [`raw/`](raw/) — the verbatim tool output every figure in it cites

## Why this example is here

Two reasons, and the second is the useful one.

**It shows the expected shape of a successful Go migration: almost nothing to change.**
`go.mod` and `go.sum` are byte-identical before and after, there are zero
architecture-constrained files, and the Dockerfile was already correct. One finding, one
check, no code edits. A report like this is the normal outcome, and an agent that finds
it unsatisfying and goes looking for work is the failure mode
`document_references/agent-scope-boundaries.md` exists to prevent.

**It shows the skill getting something wrong and being corrected by the run.** The
scanner initially reported this project's Dockerfile as defective — it hardcodes
`GOARCH=arm64` deliberately, with a comment explaining that a bare `docker build` should
fail loudly rather than ship amd64, and a `#` comment elsewhere mentions `--platform`,
which the raw grep counted. That is the most Graviton-ready Dockerfile shape there is and
the check accused it. The fix, and the fixture that pins it
(`tests/fixtures/broken/Dockerfile.literal`), came from this run.

## Reproducing it

```bash
git clone --depth 1 https://github.com/RadiumGu/go-x86-to-graviton-skill.git /tmp/gvskill
cd /path/to/payforadoption-go
go mod download
/tmp/gvskill/scripts/go_arch_scan.sh .                     # Phase 1
/tmp/gvskill/scripts/arm64_validate.sh . --cgo 0 --count 5 \
  --build-cmd 'CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -a -installsuffix cgo -o /tmp/app .'
```

`--cgo 0` and `--build-cmd` both come from the project's own Dockerfile, not from a
default. Getting those two from the deployment rather than from the developer's habits is
the difference between validating what ships and validating something else.
