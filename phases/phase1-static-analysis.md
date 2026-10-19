# Phase 1: Static Compatibility Analysis

Analyze the project **without changing it**. Every step writes its findings to the file named in parentheses and its raw output under `graviton-validation/raw/`.

The governing rule for this phase: **a verdict is only as good as its evidence.** `go list` output and a build log are facts. A grep hit is a lead. Label every grep-only verdict `CHECK` and resolve it in Phase 3 at the latest.

## Contents

- [1.1 Project Structure Analysis](#11-project-structure-analysis)
- [1.2 cgo Inventory](#12-cgo-inventory)
- [1.3 Build Constraint and Assembly Analysis](#13-build-constraint-and-assembly-analysis)
- [1.4 Non-Go Artifact and Build Configuration Detection](#14-non-go-artifact-and-build-configuration-detection)
- [1.5 Behavioral Difference Scan](#15-behavioral-difference-scan)
- [1.6 Go Version Compatibility Check](#16-go-version-compatibility-check)

---

## 1.1 Project Structure Analysis

Writes to `01-project-assessment.md`.

### Determine the build system

The build system decides which commands the rest of the skill uses. Detect all of them — a repo commonly has `go build` for developers and something else for releases, and **the release path is the one that ships to Graviton**.

```bash
# Markers, in the order they override each other for "what actually ships"
ls -1 go.mod go.sum go.work vendor/modules.txt 2>/dev/null
ls -1 Makefile makefile GNUmakefile 2>/dev/null
ls -1 .goreleaser.yaml .goreleaser.yml 2>/dev/null
ls -1 .ko.yaml 2>/dev/null
find . -name 'BUILD.bazel' -o -name 'BUILD' -not -path './vendor/*' 2>/dev/null | head -20
find . -name 'Dockerfile*' -not -path './vendor/*' -not -path './.git/*' 2>/dev/null | head -40
ls -1d .github/workflows .gitlab-ci.yml buildspec.yml codebuild 2>/dev/null
```

Dockerfiles under a non-standard name are missed by the `find` above. Also collect the files a build's `-f`/`--file`, a Compose `dockerfile:` key, and a `docker/build-push-action` `file:` input name:

```bash
{ find . -name 'Dockerfile*' -not -path './vendor/*' -not -path './.git/*';
  grep -rhoE '(-f|--file)[ =]+[^ ]+\.?[Dd]ockerfile[^ ]*' . --include='*.yml' --include='*.yaml' \
    --include='Makefile' --include='*.sh' 2>/dev/null | awk '{print $NF}';
  grep -rhoE 'dockerfile:[ ]*[^ ]+' . --include='*.yml' --include='*.yaml' 2>/dev/null | awk '{print $2}';
} | sort -u | while read -r f; do
    [ -f "$f" ] && grep -qE '^[[:space:]]*FROM' "$f" && echo "$f" || echo "UNRESOLVED: $f"
  done | tee graviton-validation/raw/dockerfiles.txt
```

An `UNRESOLVED:` line is not noise. Find that file by hand and add it to the list — a Dockerfile you did not scan is the most common way an `amd64` pin survives the whole transformation.

Record in `01-project-assessment.md`: the developer build command, the release build command, and which one this transformation validates (it must be the release one).

### Detect module, workspace and vendor layout

```bash
# Every module in the tree (more than one line = multi-module repo)
find . -name go.mod -not -path './vendor/*' | sed 's|/go.mod$||' | sort

# Workspace? go.work changes which versions resolve, so every later `go list` runs from here
[ -f go.work ] && cat go.work

# Vendored? If modules.txt agrees with go.mod, the build uses vendor/ and ignores the proxy
if [ -f vendor/modules.txt ]; then
  echo "VENDORED"
  go list -m -mod=vendor all 2>&1 | head -5
fi

# Every main package: these are the binaries that have to run on Graviton
go list -f '{{if eq .Name "main"}}{{.ImportPath}}{{end}}' ./... 2>/dev/null \
  | tee graviton-validation/raw/main-packages.txt
```

If `go list` fails here, do not proceed on grep alone — fix the resolution first. The usual causes and their fixes:

| Symptom | Cause | Fix |
|---|---|---|
| `missing go.sum entry` | cache cold, no network | `go mod download` with proxy access, or use the committed `vendor/` with `-mod=vendor` |
| `module ... found, but does not contain package` | stale `go.sum` or a replaced module | read the `replace` directives in `go.mod` |
| `unrecognized import path` for a private host | no credentials | `GOPRIVATE`/`GONOSUMDB` and the host's credentials; a private module is still arch-independent, so if you cannot reach it, mark its packages CHECK and continue |
| `go.work` member missing | workspace points outside the checkout | run from the directory the deployment runs from |

### Detect the Go version and where it came from

Four sources disagree routinely. **The one the deployment builds with wins**, and the deployment is usually the Dockerfile builder image or the CI `setup-go` version — not `go.mod`.

```bash
go version                                                    # this machine
grep -E '^(go|toolchain) ' go.mod                             # the module's floor and pinned toolchain
grep -rhoE 'golang:[0-9]+\.[0-9]+(\.[0-9]+)?[^ ]*' $(cat graviton-validation/raw/dockerfiles.txt 2>/dev/null) 2>/dev/null
grep -rhoE 'go-version[^\n]*' .github/workflows/*.y*ml 2>/dev/null
cat .go-version .tool-versions 2>/dev/null                    # goenv / asdf / mise
```

Record all four values and which one decided. A disagreement is itself worth writing down: a `go.mod` floor of 1.19 built by a 1.23 toolchain means the arm64 code generation is 1.23's, which is better than the floor suggests.

### Determine the target OS, C library and page size

Three target properties change what a native artifact must be, and all three are invisible in Go source:

```bash
# Target OS and libc family: read the runtime image, not the builder image
grep -E '^[[:space:]]*FROM' $(cat graviton-validation/raw/dockerfiles.txt) 2>/dev/null

# Classify: alpine* => musl;  debian|ubuntu|golang(non-alpine)|gcr.io/distroless => glibc
#           amazonlinux|al2023 => glibc 2.34;  scratch => none (static binary required)
```

| Runtime base | C library | Consequence for a cgo binary |
|---|---|---|
| `scratch` | none | the binary must be fully static; cgo with dynamic libs will not start |
| `gcr.io/distroless/static` | none | same as scratch |
| `gcr.io/distroless/base` | glibc | dynamic glibc cgo is fine |
| `alpine:*` | musl | a glibc-linked `.a`/`.so` will not load; needs a musl build *and* an aarch64 one |
| `amazonlinux:2023` | glibc 2.34 | an artifact built against a newer glibc will not load |
| `debian:bookworm` | glibc 2.36 | |
| `ubuntu:24.04` | glibc 2.39 | |

**Page size.** arm64 kernels run 4 KB, 16 KB or 64 KB pages; x86-64 is always 4 KB. Amazon Linux 2023, Ubuntu and Debian on arm64 use 4 KB, so the common AWS path is unchanged — but RHEL and its derivatives use 64 KB on arm64, and any code that hardcodes `4096` breaks there. Record the target's page size so Phase 1.5's hardcoded-4096 finding can be graded instead of guessed:

```bash
# On the target (or the target's container image)
getconf PAGESIZE
```

### Capture the authoritative fact base

Everything in 1.2 and 1.3 is derived from these files. Two details decide whether the capture is usable, and both have been measured rather than assumed:

> **Set `CGO_ENABLED=1` for the capture, whatever the deployment uses.** `go list` reports a package's cgo files in `CgoFiles` **only when cgo is enabled**; with `CGO_ENABLED=0` the same files move to `IgnoredGoFiles` and the package looks pure. Measured on go1.27.2/linux-arm64 against a package containing one `import "C"` file:
>
> ```
> CGO_ENABLED=0 -> Cgo=[]        Ignored=[cgo.go hash_amd64.go]
> CGO_ENABLED=1 -> Cgo=[cgo.go]  Ignored=[hash_amd64.go]
> ```
>
> `go env CGO_ENABLED` is `0` on any host without a C compiler, so a capture that inherits the environment will report a cgo project as pure Go. Phase 1.2's entire inventory then comes back empty and the hardest part of the migration is invisible.

```bash
mkdir -p graviton-validation/raw

# The resolved set as the deployment builds it today (x86 baseline).
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go list -deps -json ./... \
  > graviton-validation/raw/go-list-deps-amd64.json 2>graviton-validation/raw/go-list-deps-amd64.err

# The same set as it would resolve on Graviton.
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go list -deps -json ./... \
  > graviton-validation/raw/go-list-deps-arm64.json 2>graviton-validation/raw/go-list-deps-arm64.err

cp graviton-validation/raw/go-list-deps-arm64.json graviton-validation/raw/go-list-deps.json
go mod graph > graviton-validation/raw/module-graph.txt 2>/dev/null
```

> **A package nothing imports is silently skipped by `./...`.** Measured on the same toolchain, against a directory whose only file is gated `//go:build amd64`: with the package unimported, `go list ./...`, `go list -deps -json ./...`, `go build ./...` and `go vet ./...` **all** report zero errors on arm64. Naming the directory explicitly reports `build constraints exclude all Go files in <dir>`. Once something imports it, all four report it, with the import chain.
>
> That is defensible behavior — an unimported package blocks nothing today — but it is a latent blocker that appears the moment someone adds the import, and it belongs in the report. So the capture needs both passes.

```bash
# Pass 1: reachable packages. This is the set that blocks the build TODAY, and the
# .err file names each one with the import chain that reaches it.
grep -n 'build constraints exclude all Go files' graviton-validation/raw/go-list-deps-arm64.err

# Pass 2: every directory in the tree, named explicitly, to catch the unimported ones.
: > graviton-validation/raw/constraint-sweep-arm64.err
: > graviton-validation/raw/constraint-sweep-amd64.err
find . -name '*.go' -not -path './.git/*' 2>/dev/null | sed 's|/[^/]*$||' | sort -u \
  | while read -r d; do
      CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go list "$d" \
        >/dev/null 2>>graviton-validation/raw/constraint-sweep-arm64.err
      CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go list "$d" \
        >/dev/null 2>>graviton-validation/raw/constraint-sweep-amd64.err
    done

# A package excluded on arm64 and not on amd64 is a confirmed architecture-specific
# finding, whether or not anything imports it yet.
diff graviton-validation/raw/constraint-sweep-amd64.err \
     graviton-validation/raw/constraint-sweep-arm64.err
```

The two-pass result is what makes a Shape C verdict defensible: pass 1 says *this blocks the build*, pass 2 says *this will block the build as soon as it is imported*, and the amd64 sweep proves the exclusion is about the architecture and not about a package that is broken everywhere.

Sanity check the capture. An empty or one-line JSON file is a failed resolution, not an all-clear:

```bash
wc -c graviton-validation/raw/go-list-deps-arm64.json
grep -c '"ImportPath"' graviton-validation/raw/go-list-deps-arm64.json
```

For a `vendor/` project add `-mod=vendor`; for a workspace run from the `go.work` directory; for Bazel see [module-management-mapping.md](../document_references/module-management-mapping.md) — Bazel's resolved set comes from `bazel query`, and `go list` may not see the real dependency set at all.

### Categorize components by risk

Write one table into `01-project-assessment.md`:

| Component | Type | cgo | Arch-constrained files | Native artifacts | Initial risk |
|---|---|---|---|---|---|
| `./cmd/api` | main | no | 0 | 0 | LOW |
| `./internal/index` | lib | yes (`libz`) | 2 | 1 `.a` | HIGH |

`LOW` is a real and common verdict for Go. Do not invent risk to fill the table.

---

## 1.2 cgo Inventory

Writes to `02-cgo-report.md` and `raw/cgo-packages.txt`.

cgo is the first thing to resolve because it decides the whole shape of the migration. A pure-Go module cross-compiles and this phase takes one command. A module with cgo needs an aarch64 C toolchain and an aarch64 build of every library it links, and that is usually the entire project.

### Find every package that uses cgo

From the fact base, not from grep. **The capture must have been made with `CGO_ENABLED=1`** (Phase 1.1) — with cgo disabled, `go list` moves cgo files into `IgnoredGoFiles` and this scan returns zero for a project that is full of cgo:

```bash
# Guard against the silent-empty case before trusting a zero result
grep -c '"CgoFiles"' graviton-validation/raw/go-list-deps.json
grep -o '"IgnoredGoFiles":\[[^]]*\]' graviton-validation/raw/go-list-deps.json \
  | grep -c 'cgo'      # cgo files hiding in IgnoredGoFiles = the capture had cgo off
```

```bash
# Every package in the resolved set whose build includes C files, with the C libraries it links.
# Works with python3 or jq; python3 is used here because it needs no extra install.
python3 - <<'PY' > graviton-validation/raw/cgo-packages.txt
import json, sys
dec = json.JSONDecoder()
buf = open("graviton-validation/raw/go-list-deps.json").read()
i, n = 0, len(buf)
rows = []
while i < n:
    while i < n and buf[i] in " \t\r\n":
        i += 1
    if i >= n:
        break
    obj, i = dec.raw_decode(buf, i)
    cgo = obj.get("CgoFiles") or []
    if not cgo:
        continue
    # Skip the standard library. With CGO_ENABLED=1, runtime/cgo always reports
    # CgoFiles, and net and os/user can too; none of them is ever the finding.
    if obj.get("Standard"):
        continue
    ld = " ".join(obj.get("CgoLDFLAGS") or [])
    cf = " ".join(obj.get("CgoCFLAGS") or [])
    pkg = " ".join(obj.get("CgoPkgConfig") or [])
    rows.append(f'{obj["ImportPath"]}\tcgofiles={len(cgo)}\tLDFLAGS=[{ld}]\tCFLAGS=[{cf}]\tpkgconfig=[{pkg}]')
for r in sorted(rows):
    print(r)
print(f"# total cgo packages: {len(rows)}", file=sys.stderr)
PY

wc -l graviton-validation/raw/cgo-packages.txt
```

A zero-line result, **with the guard above confirming the capture had cgo enabled**, is the best outcome in this skill and you should say so explicitly in `02-cgo-report.md`: *"No package in the resolved dependency set uses cgo. The module is pure Go and cross-compiles to linux/arm64 without a C toolchain."* Then record the one caveat below and move to 1.3.

**The caveat for a pure-Go verdict:** the Go standard library itself uses cgo on Linux for `net` (DNS via `getaddrinfo`) and `os/user` **when `CGO_ENABLED=1` and a C toolchain is present at build time**. So "no cgo in my code" does not mean "`CGO_ENABLED` is irrelevant" — see the `net`/`os/user` item in 1.5.

### Confirm with the toolchain's own answer

```bash
# Is cgo on for this build at all?
go env CGO_ENABLED CC CXX CGO_CFLAGS CGO_LDFLAGS

# Does the module build with cgo disabled? If yes, cgo is OPTIONAL and the migration is far simpler.
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./... 2>&1 | tail -20
```

This single command splits the cgo finding into the two cases that matter:

- **CGO-OPTIONAL** — builds clean with `CGO_ENABLED=0`. The library is pulled in but not required by the code paths this module uses, or it has a pure-Go fallback behind a build tag. Record what the fallback costs (commonly: a slower implementation, or `net` switching to the pure-Go resolver). Not a blocker.
- **CGO-REQUIRED** — the build fails without cgo. Every linked C library now needs an aarch64 build, and Phase 3 must build natively on arm64 or cross-compile with `CC=aarch64-linux-gnu-gcc`.

### Resolve each C library's aarch64 availability

For each library named in `LDFLAGS`, `pkgconfig` or a bundled archive, establish **how the library reaches the build** before asking whether arm64 exists — the four routes have completely different answers. The full method, the per-route evidence standard and a table of commonly-hit modules are in [cgo-and-native-dependencies.md](../document_references/cgo-and-native-dependencies.md). Summary:

| Route | How to tell | arm64 question |
|---|---|---|
| **Vendored C source** compiled by cgo | `.c`/`.h` files inside the module | none — it compiles for whatever the C compiler targets. Needs a compiler, not a port |
| **System library** via `-lfoo` or `pkg-config` | `LDFLAGS=[-lfoo]` | does the target distro publish `libfoo` for aarch64? |
| **Bundled prebuilt archive** in the module | a committed `.a`/`.so`, often `*_linux_amd64.a` | does the module version bundle an arm64 archive? **Version-specific.** |
| **Library downloaded at build time** | a `curl`/`wget` in a Makefile, `go:generate` or Dockerfile | does the download URL have an arm64 variant? |

Classify each library and record the evidence inline:

- `BLOCKER` — no aarch64 build exists and none can be produced (an x86-only library by nature, e.g. an Intel-specific math kernel). This is a user decision: substitute, drop the feature, or do not migrate this service
- `NEEDS AARCH64 BUILD` — exists for aarch64 but the project currently obtains an x86 one. Phase 2.1 fixes it
- `BUNDLED-OK` — the module version already bundles an arm64 archive; cite the file name you found
- `CGO-OPTIONAL` — covered above
- `NOT CGO` — the package appeared in a grep but `go list` reports no `CgoFiles`. Grep was wrong; say so

### Flag x86-only flags in `#cgo` directives

These compile on x86 and fail on arm64 with `unrecognized command-line option`:

```bash
grep -rn --include='*.go' -E '^//[[:space:]]*#cgo' . \
  | grep -E '\-m(64|32|arch|tune|sse[0-9.]*|avx[0-9]*|aes|popcnt|fma)' \
  | tee -a graviton-validation/raw/cgo-packages.txt
```

Also check the environment, which is where these hide more often than in source:

```bash
grep -rn -E 'CGO_(C|CXX|LD)FLAGS' . --include='Makefile' --include='*.mk' --include='*.sh' \
  --include='Dockerfile*' --include='*.yml' --include='*.yaml' 2>/dev/null
```

A `#cgo` line is made per-architecture in Phase 2.1 (`#cgo amd64 CFLAGS: -msse4.2`), never deleted.

---

## 1.3 Build Constraint and Assembly Analysis

Writes to `03-build-constraint-report.md` and `raw/build-constraints.txt`.

This is where a pure-Go project still fails, and it is the finding most often missed, because it lives in `vendor/` or three modules deep rather than in the code anyone reads.

### Inventory every architecture-constrained file

Cover both constraint syntaxes (`//go:build`, and the pre-1.17 `// +build` that is still present in older dependencies) and the filename-suffix form, which has **no marker inside the file at all**:

```bash
: > graviton-validation/raw/build-constraints.txt

# Form A: filename suffix. _amd64.go / _amd64.s / _386.s / _arm64.go ... The suffix IS the constraint.
find . -type d -name .git -prune -o -type f \( -name '*_amd64*.go' -o -name '*_amd64*.s' \
  -o -name '*_386*.go' -o -name '*_386*.s' -o -name '*_arm64*.go' -o -name '*_arm64*.s' \
  -o -name '*_arm*.go' -o -name '*_arm*.s' \) -print 2>/dev/null \
  | sed 's/^/SUFFIX\t/' >> graviton-validation/raw/build-constraints.txt

# Form B: an explicit constraint line naming an architecture
grep -rn --include='*.go' --include='*.s' -E '^//[[:space:]]*(go:build|\+build)[^\n]*(amd64|386|arm64|arm)' . 2>/dev/null \
  | sed 's/^/CONSTRAINT\t/' >> graviton-validation/raw/build-constraints.txt

wc -l graviton-validation/raw/build-constraints.txt
```

**Scan `vendor/` too.** The commands above do. Do not add `-not -path './vendor/*'` here, however tempting the noise reduction is: a vendored dependency's amd64-only assembly is compiled into your binary and is exactly the blocker you are looking for.

### Classify each finding into one of three shapes

The count is meaningless; the shape is everything. For each package that has an architecture-constrained file, list the whole constrained family in that directory and decide:

```bash
# For a directory of interest, show the family so the shape is visible at a glance
d=internal/hash
ls -1 "$d" | grep -E '_(amd64|arm64|arm|386|generic|noasm|purego)[^.]*\.(go|s)$'
```

| Shape | Looks like | Verdict | Action |
|---|---|---|---|
| **A. amd64 + arm64 siblings** | `hash_amd64.s`, `hash_arm64.s`, `hash_asm.go` | FINE | none. Record it as fine — this is a well-ported dependency and saying so prevents a pointless Phase 2 |
| **B. amd64 + generic fallback** | `hash_amd64.go` plus `hash_generic.go` gated `//go:build !amd64`, or a `purego`/`noasm` tag | BUILDS, SLOWER | non-blocking. Record the expected performance delta as a CHECK for Phase 3 benchmarking. **Do not "fix" this** |
| **C. amd64 only, no fallback** | `hash_amd64.go` and nothing else | **BLOCKER** | Phase 2.2. The build fails with `build constraints exclude all Go files in <dir>` |

Shape C is confirmed, not inferred, by the two capture passes from 1.1:

```bash
# Pass 1 - reachable packages, with the import chain that makes them a blocker today
grep -n 'build constraints exclude all Go files' graviton-validation/raw/go-list-deps-arm64.err

# Pass 2 - every directory named explicitly, which is the only way to see an
# unimported Shape C package (measured: ./... skips it silently, in go list,
# go build AND go vet). Diff against the amd64 sweep so the verdict is
# architecture-specific rather than "this package is broken everywhere".
diff graviton-validation/raw/constraint-sweep-amd64.err \
     graviton-validation/raw/constraint-sweep-arm64.err
```

Report the two kinds separately — they need different urgency:

| Pass | Meaning | Urgency |
|---|---|---|
| in `go-list-deps-arm64.err` (reachable) | **blocks the arm64 build now** | fix in Phase 2.2 |
| only in the sweep (unimported) | latent: blocks the build the moment anything imports it | record it; fix it if it is cheap, and say so either way |

Shape B has a quieter and nastier variant worth calling out in the report: a fallback that is not merely slower but **functionally different** — a stub that returns an error, logs "unsupported platform" and continues, or silently returns zero. Read the fallback body; do not assume "generic" means "equivalent":

```bash
# Read the fallback implementations, do not just confirm they exist
grep -rn --include='*.go' -iE 'unsupported (platform|architecture)|not implemented on|panic\("unsupported' . 2>/dev/null
```

### Inventory assembly

```bash
# Every .s file, grouped by the architecture its name implies
find . -type d -name .git -prune -o -name '*.s' -print 2>/dev/null \
  | awk -F/ '{f=$NF; arch="UNSUFFIXED"; if (f ~ /_amd64/) arch="amd64";
             else if (f ~ /_arm64/) arch="arm64"; else if (f ~ /_arm\./) arch="arm";
             else if (f ~ /_386/) arch="386"; print arch "\t" $0}' | sort
```

An `UNSUFFIXED` `.s` file is a real trap: it has no filename constraint, so it is compiled for **every** architecture unless a `//go:build` line inside it says otherwise. Open each one and check:

```bash
# For each UNSUFFIXED .s file, does it carry its own constraint?
head -5 path/to/file.s
```

If it carries none and contains x86 mnemonics, the package cannot build for arm64 and no filename suggests why. This is a Shape C blocker wearing a disguise.

Hand-written arm64 assembly that *does* exist is in scope only for validation, not for review: it is correct or the tests fail. Record its presence so Phase 3 knows the tests matter more than usual.

---

## 1.4 Non-Go Artifact and Build Configuration Detection

Writes to `04-artifact-and-build-config-findings.md`, `raw/native-artifact-scan.txt`, `raw/image-platforms.txt`.

Go source is portable; the things around it are not. This step covers everything in the repo that is already a compiled binary or that selects an architecture.

### Committed native artifacts, judged by content

A filename is a hint, not evidence. `file` reads the ELF header:

```bash
: > graviton-validation/raw/native-artifact-scan.txt
find . -type d -name .git -prune -o -type f \
  \( -name '*.so' -o -name '*.so.*' -o -name '*.a' -o -name '*.dylib' -o -name '*.dll' \
     -o -name '*.o' -o -perm -u+x \) -print 2>/dev/null \
  | while read -r f; do
      case "$(head -c 4 "$f" 2>/dev/null | od -An -c | tr -d ' \n')" in
        *ELF*|!*arch*) echo "$f: $(file -b "$f")" ;;
      esac
    done | sort | tee graviton-validation/raw/native-artifact-scan.txt

# Anything reported x86-64 / 80386 is a finding
grep -iE 'x86-64|80386|i386' graviton-validation/raw/native-artifact-scan.txt
```

`file` on a static archive (`.a`) reports `current ar archive` without an architecture. Read a member:

```bash
ar t libfoo.a | head -1                       # pick a member
ar p libfoo.a "$(ar t libfoo.a | head -1)" > /tmp/m.o && file -b /tmp/m.o && rm -f /tmp/m.o
```

A module that bundles per-platform archives usually names them, and the presence or absence of the arm64 one is the whole verdict:

```bash
find . -path '*/vendor/*' -name '*.a' 2>/dev/null | grep -iE 'arm64|aarch64|amd64|x86' | sort
ls -1 "$(go env GOMODCACHE)" >/dev/null 2>&1 && \
  find "$(go env GOMODCACHE)" -name '*_linux_arm64.a' 2>/dev/null | head -10
```

### Binaries downloaded at build, deploy or run time

These never appear in `go.mod` and are a frequent cause of a container that builds and then dies with `exec format error`:

```bash
grep -rn -E '(curl|wget|ADD https?://|go install|GOBIN=)' . \
  --include='Dockerfile*' --include='Makefile' --include='*.mk' --include='*.sh' \
  --include='*.yml' --include='*.yaml' --exclude-dir=.git --exclude-dir=vendor 2>/dev/null \
  | grep -vE '^\s*#'
```

Then, for each download, decide whether the URL is architecture-aware. The dangerous ones are those with no architecture in the URL at all — they still fetch a build **for one**:

```bash
# Hardcoded x86 in a download URL
grep -rn -E 'https?://[^ "'"'"']*((amd64|x86_64|386|x86-64)[^ "'"'"']*)' . \
  --include='Dockerfile*' --include='Makefile' --include='*.sh' --include='*.yml' --include='*.yaml' \
  --exclude-dir=.git --exclude-dir=vendor 2>/dev/null
```

Tools commonly fetched by Go repos, each of which must be the arm64 build on an arm64 builder: `protoc`, `protoc-gen-go`, `protoc-gen-go-grpc`, `golangci-lint`, `mockgen`, `migrate`, `goose`, `dockerize`, `grpc_health_probe`, `wait-for-it`, `hadolint`, `kubectl`, `helm`, `aws-lambda-rie`. Of these, `grpc_health_probe` and `dockerize` are the ones that end up inside the runtime image and so break at run time rather than build time.

### Image platforms, from the registry

```bash
: > graviton-validation/raw/image-platforms.txt
# Every image reference: FROM lines of the Dockerfiles found in 1.1 (not stage names), image: keys in
# YAML/JSON, and images named in test code. A reference built from a variable is left out: resolve by hand.
{ grep -hE '^[[:space:]]*FROM' $(cat graviton-validation/raw/dockerfiles.txt 2>/dev/null) 2>/dev/null \
    | awk '{for(i=2;i<=NF;i++) if ($i !~ /^--/ && $i != "AS" && $i != "as") {print $i; break}}';
  grep -rhoE '^[[:space:]]*image:[[:space:]]*["'"'"']?[^ "'"'"']+' . --include='*.yml' --include='*.yaml' \
    --exclude-dir=.git --exclude-dir=vendor 2>/dev/null | awk -F: '{print $2":"$3}' | tr -d ' "'"'"'';
} | grep -vE '^\$|^$' | sort -u | while read -r img; do
    plats=$(docker manifest inspect "$img" 2>/dev/null \
      | python3 -c 'import json,sys
try:
  m=json.load(sys.stdin)
except Exception:
  print("CHECK"); raise SystemExit
ms=m.get("manifests")
if ms: print(",".join(sorted({(x.get("platform") or {}).get("os","?")+"/"+((x.get("platform") or {}).get("architecture","?")) for x in ms})))
else: print("single-arch-or-CHECK")' 2>/dev/null)
    echo "${img}\t${plats:-CHECK}"
  done | tee graviton-validation/raw/image-platforms.txt

grep -v 'linux/arm64' graviton-validation/raw/image-platforms.txt    # the findings
```

Without a container runtime, or without the login a private registry needs, the line is `CHECK` — not a failure. Say `CHECK` in the report; do not guess that an image is multi-arch because it is popular.

A stage pinned with `FROM --platform=linux/amd64` is a separate and louder finding; it survives a correct `buildx` invocation and silently produces an x86 layer:

```bash
grep -nE '^[[:space:]]*FROM[[:space:]]+--platform=' $(cat graviton-validation/raw/dockerfiles.txt) 2>/dev/null
```

`--platform=$BUILDPLATFORM` on a **builder** stage is correct and desirable for Go (see Phase 2.4); `--platform=linux/amd64` anywhere, and `--platform=$BUILDPLATFORM` on the **runtime** stage, are findings.

### Architecture selection in build scripts

```bash
# GOARCH / GOAMD64 / GOARM64 pinned anywhere
grep -rn -E 'GOARCH|GOAMD64|GOARM64|GOOS' . \
  --include='Makefile' --include='*.mk' --include='*.sh' --include='Dockerfile*' \
  --include='*.yml' --include='*.yaml' --include='*.json' --include='*.hcl' \
  --exclude-dir=.git --exclude-dir=vendor 2>/dev/null

# GoReleaser: is arm64 in the goarch list?
grep -A8 -nE '^[[:space:]]*(goos|goarch):' .goreleaser.y*ml 2>/dev/null

# C/C++ march flags that would reach an arm64 compiler
grep -rn -E '\-march=|\-mtune=|\-msse|\-mavx|\-maes' . \
  --include='Makefile' --include='*.mk' --include='*.sh' --include='Dockerfile*' \
  --include='CMakeLists.txt' --exclude-dir=.git 2>/dev/null
```

**`GOAMD64` deserves its own line in the report.** `GOAMD64=v3` is a legitimate x86 optimization that is simply inert on arm64, so it does not fail — but a Makefile that sets it unconditionally signals that someone tuned for x86 microarchitecture, and the arm64 counterpart (`GOARM64`, Go 1.23+) is almost certainly unset. Record both.

### Deployment descriptors

An architecture that is **absent** defaults to x86 almost everywhere, so "no finding" requires checking for the absence, not just the wrong value:

| Platform | Setting | Default when absent |
|---|---|---|
| Lambda (SAM/CFN/CDK/Terraform/serverless) | `Architectures: [arm64]` / `architecture: ARM_64` | `x86_64` |
| ECS task definition | `runtimePlatform.cpuArchitecture: ARM64` | `X86_64` |
| EKS / Kubernetes | `nodeSelector: kubernetes.io/arch: arm64`, plus a multi-arch image | scheduler picks any node |
| EC2 / ASG / launch template | instance type `c7g`/`c8g`/`m7g`/`m8g`/`r7g`/`r8g` **and** an arm64 AMI | the pinned type and AMI |
| App Runner / Batch / CodeBuild | the service's architecture field and image | x86 |

```bash
grep -rn -iE 'architectures?:|cpuArchitecture|runtimePlatform|kubernetes\.io/arch|InstanceType|instance_type' . \
  --include='*.yml' --include='*.yaml' --include='*.json' --include='*.tf' --include='*.ts' --include='*.py' \
  --exclude-dir=.git --exclude-dir=vendor --exclude-dir=node_modules 2>/dev/null | head -60

# CDK apps: the constructs that take an architecture, in each folder with a cdk.json
# (a construct that sets none gets x86_64)
find . -name cdk.json -not -path './node_modules/*' 2>/dev/null
```

An arm64 AMI is a separate check from an arm64 instance type, and getting one without the other is the most common EC2 Graviton mistake: the instance launches and the AMI will not boot.

---

## 1.5 Behavioral Difference Scan

Writes to `05-behavioral-findings.md`.

Everything in this step compiles cleanly for arm64. That is precisely why it is here. These are the findings that reach production.

### The memory model (the one that matters most, and cannot be grepped)

x86-64 is Total Store Order. arm64 is weakly ordered: stores from one core become visible to another in an order the program did not write, unless the program used a synchronization primitive. A Go program **without** data races behaves identically on both — the Go memory model is architecture-independent for race-free programs. A Go program **with** a data race has undefined behavior on both and, in practice, works on x86 and intermittently fails on arm64.

There is no static pattern to find. The scan for this is Phase 3.2's `go test -race ./...` **on arm64**, and it is a mandatory exit criterion. In this step, record the things that raise the prior probability so Phase 3 knows where to look:

```bash
# Hand-rolled synchronization is where races live. Each hit is a place to read, not a defect.
grep -rn --include='*.go' -E '\bgo func\b' . --exclude-dir=vendor 2>/dev/null | wc -l
grep -rn --include='*.go' -E 'sync/atomic|atomic\.(Load|Store|Add|Swap|Compare)' . --exclude-dir=vendor 2>/dev/null
grep -rn --include='*.go' -E '//[[:space:]]*(nolint|race|NOTE).*(race|lock|atomic)' . --exclude-dir=vendor 2>/dev/null

# A test suite that cannot run under -race at all is itself a finding (CGO_ENABLED=0 disables -race on
# some platforms; -race needs cgo on Linux for the runtime, available on linux/arm64 since Go 1.14)
grep -rn -E 'go test' . --include='Makefile' --include='*.sh' --include='*.yml' --include='*.yaml' \
  --exclude-dir=.git 2>/dev/null | grep -v -- '-race' | head -20
```

If the project's CI never runs `-race`, say so plainly in the report. It means no one has ever checked, and the migration is carrying an unknown.

### x86 CPU feature gates

```bash
# golang.org/x/sys/cpu and runtime feature detection
grep -rn --include='*.go' -E 'cpu\.X86\.|cpu\.Initialized|HasAVX|HasSSE|HasAES|HasBMI|HasPOPCNT' . 2>/dev/null

# The arm64 counterparts, for comparison: a file that reads cpu.X86 and never cpu.ARM64 has no arm64 path
grep -rn --include='*.go' -E 'cpu\.ARM64\.' . 2>/dev/null

# Direct GOARCH comparisons
grep -rn --include='*.go' -E 'runtime\.GOARCH|GOARCH[[:space:]]*==' . --exclude-dir=vendor 2>/dev/null

# The risky shape: a file that compares against amd64/x86 but never mentions arm64/aarch64
grep -rl --include='*.go' -E '"amd64"|"x86_64"' . --exclude-dir=vendor 2>/dev/null \
  | while read -r f; do grep -qE 'arm64|aarch64' "$f" || echo "NO-ARM64-BRANCH: $f"; done
```

A `cpu.X86.HasAVX2` gate with an `else` that is a correct generic implementation is **fine** and must be recorded as fine. A gate whose `else` panics, returns an error, or disables a feature is a finding. Read the `else`.

### Direct syscall numbers and seccomp

```bash
# syscall.SYS_* constants. Several do not exist on arm64 at all: SYS_OPEN, SYS_FORK, SYS_PIPE,
# SYS_DUP2, SYS_POLL, SYS_RENAME, SYS_UNLINK, SYS_MKDIR, SYS_SYMLINK, SYS_EPOLL_CREATE,
# SYS_INOTIFY_INIT (arm64 has openat, clone, pipe2, dup3, ppoll, renameat, unlinkat, mkdirat,
# symlinkat, epoll_create1, inotify_init1). A missing constant is a COMPILE error - loud and safe.
grep -rn --include='*.go' -E 'syscall\.SYS_|unix\.SYS_|syscall\.Syscall\(' . --exclude-dir=vendor 2>/dev/null

# The silent variant: a NUMERIC seccomp/BPF filter. The numbers differ between architectures
# (x86-64 186 is gettid; on arm64 178 is gettid and 186 is msgget), so an x86 numeric filter on
# arm64 blocks or permits the wrong calls with no error at all.
grep -rn -iE 'seccomp|SCMP_|BPF_|AUDIT_ARCH' . --include='*.go' --include='*.json' --include='*.yaml' \
  --include='*.yml' --exclude-dir=.git --exclude-dir=vendor 2>/dev/null
```

A seccomp profile written with syscall **names** (the Docker/containerd JSON format) is portable. One written with numbers, or one pinned to `AUDIT_ARCH_X86_64`, is a finding and a serious one: it changes security posture silently.

### Page size

```bash
grep -rn --include='*.go' -E '\b4096\b|PageSize|Getpagesize|MAP_|mmap' . --exclude-dir=vendor 2>/dev/null
```

Grade each hit against the target page size recorded in 1.1. On a 4 KB arm64 target (Amazon Linux 2023, Ubuntu, Debian) a hardcoded `4096` is latent, not broken — record it as a CHECK with that reasoning. On a 64 KB target it is a blocker.

### Floating point: FMA fusion

This one is real, specified, and surprises people. The Go specification permits an implementation to fuse floating-point operations: `x*y + z` may compile to a single fused multiply-add. **Go emits `FMADD` on arm64 and does not fuse on amd64.** So the same expression can produce results differing in the last bits between the two architectures — correctly, per the spec.

```bash
# Tests that assert exact float equality are where this surfaces
grep -rn --include='*_test.go' -E '(==|!=)[[:space:]]*[0-9]+\.[0-9]|Equal\([^)]*[0-9]\.[0-9]' . \
  --exclude-dir=vendor 2>/dev/null | head -40

# Expressions of the fusible shape in non-test code, for context
grep -rn --include='*.go' -E '[a-zA-Z0-9_)\]]+[[:space:]]*\*[[:space:]]*[a-zA-Z0-9_(\[]+[[:space:]]*\+' . \
  --exclude-dir=vendor --exclude='*_test.go' 2>/dev/null | head -20
```

The fix in Phase 2.5 is one of: force the rounding with an explicit conversion (`float64(x*y) + z`, which the spec says rounds to the target type and therefore defeats fusion), compare with a tolerance, or accept the difference and update the expectation. The fix is **never** to disable optimization globally.

Financial and `math/big` code is unaffected — integer and arbitrary-precision arithmetic is exact on both.

### cgo-dependent `net` and `os/user`

With `CGO_ENABLED=1` and a C toolchain, Go's `net` package can use the system resolver (`getaddrinfo`, honoring `/etc/nsswitch.conf` and NSS modules) and `os/user` can use libc's passwd lookup. With `CGO_ENABLED=0`, or with the `netgo`/`osusergo` build tags, both switch to pure-Go implementations that read `/etc/resolv.conf` and `/etc/passwd` directly and **ignore NSS**.

This is not an arm64 difference. It becomes one the moment a migration changes `CGO_ENABLED` to make a cgo link error go away — which is the single most tempting shortcut in this entire transformation:

```bash
grep -rn -E 'CGO_ENABLED|netgo|osusergo|-tags' . \
  --include='Makefile' --include='*.mk' --include='*.sh' --include='Dockerfile*' \
  --include='*.yml' --include='*.yaml' --exclude-dir=.git 2>/dev/null
```

Record the current value. If Phase 2 changes it, that is a behavior change requiring user confirmation, documented in `05-behavioral-findings.md` — not a build fix. Environments that rely on LDAP/SSSD via NSS, or on a container DNS setup that `getaddrinfo` handles differently, will change behavior.

### 64-bit atomics and `unsafe`

```bash
grep -rn --include='*.go' -E 'unsafe\.(Pointer|Sizeof|Offsetof|Alignof|Slice|String)' . --exclude-dir=vendor 2>/dev/null
```

On arm64, as on amd64, `int` and pointers are 64-bit and 64-bit values are naturally aligned, so the classic `sync/atomic` alignment panic is a **32-bit** problem (`GOARCH=arm`, `386`) and not a Graviton one. Record `unsafe` usage as a CHECK to be resolved by the Phase 3 test run rather than as a predicted failure — and resist writing it up as an arm64 risk, because on this specific migration path it usually is not one. If the project also targets `GOARCH=arm` (32-bit, e.g. an edge build), that is a different migration and out of scope here.

---

## 1.6 Go Version Compatibility Check

Writes to `01-project-assessment.md`.

**Document the version; do not change it.** A toolchain bump is one decision affecting the entire module and every dependency's resolution, and it is only in scope when it is the *only* path to an arm64 build (`go.toolchain_bump` in `skill-config.md`).

Record:

1. The version the deployment builds with, and which of the four sources in 1.1 decided it
2. Its support status. Go supports the two most recent major releases ([Go release policy](https://go.dev/doc/devel/release#policy)); look the current releases up rather than recalling them
3. The arm64-relevant floors below, and whether the project is above or below each

| Floor | What it changes on arm64 | If below |
|---|---|---|
| Go 1.5 | `linux/arm64` is a supported port | not a realistic finding |
| Go 1.14 | race detector supported on `linux/arm64` | **blocking for exit criterion 9** — the race check cannot run |
| Go 1.18 | register-based calling convention on arm64 | measurable throughput left on the table; a recommendation, not a blocker |
| Go 1.20 | `go test -skip` available (used by Phase 3's INFRA handling) | use a narrowed `-run` pattern instead |
| Go 1.21 | `toolchain` directive; `GOTOOLCHAIN` auto-switching | version pinning is advisory only |
| Go 1.23 | `GOARM64` microarchitecture level (default `v8.0`) | the `GOARM64` recommendation in `06` is not available; note it as blocked-by-version |

Nothing on this list is a blocker except Go 1.14 for the race detector, and no realistic project is below it. Say that. A migration report that recommends a Go upgrade for arm64 reasons, when the project is on a supported release, is scope creep — see [agent-scope-boundaries.md](../document_references/agent-scope-boundaries.md).

---

## Phase 1 exit

Before moving to Phase 2, confirm:

- [ ] `raw/go-list-deps-arm64.json` is non-empty and `raw/go-list-deps-arm64.err` has been read
- [ ] `02-cgo-report.md` states a cgo count, even when it is zero, and names the C library route for each one
- [ ] `03-build-constraint-report.md` classifies every constrained file as Shape A, B or C, including those in `vendor/`
- [ ] `04-...-findings.md` lists each image with its registry platforms or an explicit `CHECK`
- [ ] `05-behavioral-findings.md` records whether the project has ever run `-race`
- [ ] Every verdict derived from grep alone is labelled `CHECK`
- [ ] No file outside `graviton-validation/` has been modified
