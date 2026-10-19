# Build Constraints and Assembly — Evidence Standard

The evidence standard for every verdict in `03-build-constraint-report.md`. Read during Phase 1.3 and whenever a constraint verdict needs backing.

This is the class of finding that breaks a *pure-Go* Graviton migration, and it is routinely missed because it usually lives in a dependency rather than in project code.

## Contents

- [How Go decides which files to build](#how-go-decides-which-files-to-build)
- [The authoritative detection](#the-authoritative-detection)
- [The three shapes](#the-three-shapes)
- [Shape C in disguise](#shape-c-in-disguise)
- [Reading a fallback implementation](#reading-a-fallback-implementation)
- [Assembly](#assembly)
- [Build tags projects use for a portable path](#build-tags-projects-use-for-a-portable-path)
- [x/sys/cpu feature bits on Graviton](#xsyscpu-feature-bits-on-graviton)
- [False verdicts](#false-verdicts)

---

## How Go decides which files to build

Two mechanisms, and **the filename one has no marker inside the file**:

**1. The filename suffix.** A file named `*_GOARCH.go`, `*_GOOS.go` or `*_GOOS_GOARCH.go` is built only for that target. The suffix is a constraint even with no comment in the file:

```
hash_amd64.go      built only for GOARCH=amd64
hash_arm64.s       built only for GOARCH=arm64
hash_linux_amd64.go  built only for linux/amd64
hash_asm.go        NOT a constraint - "asm" is not a known GOOS or GOARCH, so this
                   file builds everywhere unless it carries a //go:build line
```

The last line is the subtlety that makes this mechanism error-prone in both directions: `_amd64` constrains, `_asm` does not, and only knowing the GOOS/GOARCH value list tells you which is which. `_arm.go` constrains to 32-bit ARM, **not** arm64 — these are separate `GOARCH` values and a file named `_arm.go` is excluded on Graviton.

**2. The `//go:build` line** (Go 1.17+), or the legacy `// +build` line that still appears in older dependencies, placed before the package clause:

```go
//go:build amd64 && linux
package hash
```

Both mechanisms apply at once. **The filename suffix wins when they conflict**: a file named `impl_amd64.go` carrying `//go:build amd64 || arm64` is still built only for amd64, because the suffix excludes it before the comment is read. This is the single most common mistake when fixing a Shape C finding — widening the `//go:build` line and leaving the filename alone changes nothing, and the build fails identically.

When no file in a directory satisfies the constraints, the build fails with:

```
build constraints exclude all Go files in /path/to/dir
```

That message, and not a grep, is the confirmation of a blocker.

---

## The authoritative detection

Two passes are needed, and the reason is measured rather than assumed.

### Pass 1 — reachable packages

```bash
CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go list -deps -json ./... \
  > graviton-validation/raw/go-list-deps-arm64.json \
  2>graviton-validation/raw/go-list-deps-arm64.err

CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go list -deps -json ./... \
  > graviton-validation/raw/go-list-deps-amd64.json \
  2>graviton-validation/raw/go-list-deps-amd64.err

diff graviton-validation/raw/go-list-deps-amd64.err graviton-validation/raw/go-list-deps-arm64.err
```

A message present in the arm64 `.err` and absent from the amd64 one is a confirmed, located, architecture-specific blocker. When the package is reached through an import, the message carries the chain, which is the fastest route to the fix:

```
package example.com/svc/cmd/app
	imports example.com/svc/internal/simd: build constraints exclude all Go files in /path/internal/simd
```

### Pass 2 — the directories nothing imports

`./...` **silently skips a package that has no buildable files for the target.** Measured on go1.27.2/linux-arm64 against a directory whose only file is gated `//go:build amd64`, with nothing importing it:

| Command | Constraint errors reported |
|---|---|
| `go list ./...` | 0 |
| `go list -deps -json ./...` | 0 |
| `go build ./...` | 0 |
| `go vet ./...` | 0 |
| `go list ./internal/simd` (named explicitly) | **1** |

Once a package imports it, all four report it. So `./...` covers exactly the set that blocks the build today, and misses the latent ones:

```bash
: > graviton-validation/raw/constraint-sweep-arm64.err
: > graviton-validation/raw/constraint-sweep-amd64.err
find . -name '*.go' -not -path './.git/*' 2>/dev/null | sed 's|/[^/]*$||' | sort -u \
  | while read -r d; do
      CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go list "$d" \
        >/dev/null 2>>graviton-validation/raw/constraint-sweep-arm64.err
      CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go list "$d" \
        >/dev/null 2>>graviton-validation/raw/constraint-sweep-amd64.err
    done

diff graviton-validation/raw/constraint-sweep-amd64.err \
     graviton-validation/raw/constraint-sweep-arm64.err
```

Report the two kinds separately: reachable = blocks the build now; sweep-only = blocks it the moment someone adds the import.

### The quieter form

A package that has *a* file for arm64, where that file does not declare everything the rest of the package references, produces no `go list` error and fails at compile time:

```
undefined: fastSum
```

Only the build catches that one (Phase 3.1).

### Examining one suspect package

`go list` can be asked which files it would actually compile, per architecture:

```bash
pkg=./internal/hash
for a in amd64 arm64; do
  echo "=== GOARCH=$a ==="
  CGO_ENABLED=1 GOOS=linux GOARCH=$a go list \
    -f '{{.GoFiles}} {{.SFiles}} {{.CgoFiles}} IGNORED={{.IgnoredGoFiles}}' "$pkg" 2>&1
done
```

`IgnoredGoFiles` names the files excluded by constraints. A package whose `GoFiles` is empty on arm64 and non-empty on amd64 is Shape C, shown directly. Note that `CgoFiles` is populated only with `CGO_ENABLED=1`; with cgo off, the cgo files appear in `IgnoredGoFiles` instead — measured:

```
CGO_ENABLED=0 -> Cgo=[]        Ignored=[cgo.go hash_amd64.go]
CGO_ENABLED=1 -> Cgo=[cgo.go]  Ignored=[hash_amd64.go]
```

---

## The three shapes

The count of architecture-constrained files carries no information. The shape does.

### Shape A — amd64 and arm64 siblings

```
internal/hash/
├── hash.go              // dispatcher, no constraint
├── hash_asm.go          //go:build amd64 || arm64   (declarations)
├── hash_amd64.s
└── hash_arm64.s
```

**Verdict: FINE. No action.** This is what a well-ported dependency looks like, and `golang.org/x/crypto`, `golang.org/x/sys` and the standard library are full of it.

Record it as fine, explicitly. An unlabelled Shape A family invites a later reader — or a later agent — to "fix" it.

### Shape B — amd64 fast path with a generic fallback

```
internal/compress/
├── compress_amd64.go    //go:build amd64        (SIMD path)
└── compress_generic.go  //go:build !amd64       (portable Go)
```

**Verdict: BUILDS, POSSIBLY SLOWER. Non-blocking. Do not change it.**

The correct handling is a benchmark note for Phase 3.2, not a code change. Writing an arm64 assembly path here is out of scope (`agent-scope-boundaries.md`, out-of-scope item 8) — the generic path is correct, and arm64 performance work is the user's, after measurement.

Two things to verify before accepting Shape B:

1. **the fallback is a real implementation**, not a stub (next section)
2. **the tests are not themselves gated on amd64**, or the fallback ships untested:
   ```bash
   grep -lE '^//[[:space:]]*(go:build|\+build)[^\n]*amd64' internal/compress/*_test.go
   ```
   A hit here is a finding in its own right: widen the test file's constraint so the generic path is covered.

### Shape C — amd64 only, no fallback

```
internal/simd/
└── simd_amd64.go        //go:build amd64
```

**Verdict: BLOCKER.** Confirmed by `build constraints exclude all Go files in ./internal/simd` in the arm64 `.err` file.

Fixed in Phase 2.2, in this order of preference: relax the gate if the body is portable (and rename the file if its suffix carries the constraint); add a generic sibling; upgrade the dependency that owns it; `replace` to a fork; use a `purego`/`noasm` tag the dependency offers. Writing arm64 assembly is last and rarely justified.

---

## Shape C in disguise

Four variants that do not look like Shape C and behave like it:

**1. The unsuffixed `.s` file.** No filename constraint, so it compiles for every architecture — and fails on arm64 if it contains x86 mnemonics:

```bash
find . -name '*.s' -not -name '*_*64*.s' -not -name '*_arm*.s' -not -name '*_386*.s' 2>/dev/null \
  | while read -r f; do
      head -5 "$f" | grep -qE '^//[[:space:]]*(go:build|\+build)' \
        || echo "UNCONSTRAINED ASM: $f"
    done
```

Each hit must be opened. If it has no internal constraint and holds x86 instructions, the package cannot build for arm64 and nothing in the filename says why.

**2. The `_arm.go` file mistaken for arm64.** `GOARCH=arm` is 32-bit ARM. A package with `impl_amd64.go` and `impl_arm.go` and nothing else is Shape C on Graviton, even though it looks ported:

```bash
# Files that constrain to 32-bit arm, in a package with no arm64 sibling
find . -name '*_arm.go' -o -name '*_arm.s' 2>/dev/null | while read -r f; do
  d=$(dirname "$f")
  ls "$d" | grep -q 'arm64' || echo "32-BIT ARM ONLY (no arm64 sibling): $f"
done
```

**3. The negated-constraint fallback that excludes arm64 too.** A fallback gated `//go:build !amd64 && !arm64` — written when arm64 had its own path that was later deleted, or copied from a project that did — leaves a hole:

```bash
grep -rn --include='*.go' -E '^//[[:space:]]*(go:build|\+build)[^\n]*!amd64[^\n]*!arm64' . 2>/dev/null
```

**4. The build tag the project sets globally.** A constraint satisfied only when a tag is passed, where the Makefile passes it and a bare `go build` does not — or the reverse. The deployment's build command is authoritative:

```bash
grep -rn -- '-tags' . --include='Makefile' --include='*.mk' --include='Dockerfile*' \
  --include='*.sh' --include='*.yml' --include='*.yaml' --exclude-dir=.git 2>/dev/null
```

Run the Phase 1.1 capture with the deployment's tags, or the constraint landscape you analysed is not the one that ships.

---

## Reading a fallback implementation

A fallback's existence is not evidence that it works. Read the body. Four patterns, in descending order of acceptability:

```go
// 1. GOOD - a real portable implementation
//go:build !amd64
func Sum(b []byte) uint64 { /* ...actual Go... */ }

// 2. ACCEPTABLE, note it - correct but degrades a documented capability
//go:build !amd64
func Sum(b []byte) uint64 { return sumSlowButCorrect(b) }   // ~4x slower, same output

// 3. FINDING - compiles, returns wrong answers
//go:build !amd64
func Sum(b []byte) uint64 { return 0 }

// 4. FINDING - compiles, fails at run time on every arm64 call
//go:build !amd64
func Sum(b []byte) uint64 { panic("unsupported architecture") }
```

Patterns 3 and 4 pass the build and pass `go vet`. Pattern 3 can pass the tests too, if the tests are gated on amd64 (Shape B's second check). This is the worst outcome in the whole constraint class: a green migration that returns wrong data on Graviton.

Hunt for them directly:

```bash
grep -rn --include='*.go' -iE \
  'panic\("(unsupported|not implemented|no (asm|assembly))' . --exclude-dir=vendor 2>/dev/null
grep -rn --include='*.go' -iE \
  'unsupported (platform|architecture|arch)|not (supported|implemented) on (this )?(platform|arch)' . 2>/dev/null

# And in dependencies, for the packages Phase 1.3 flagged
for d in $(go list -deps -f '{{.Dir}}' ./... 2>/dev/null | grep "$(go env GOMODCACHE)"); do
  grep -ln -iE 'panic\("unsupported (platform|arch)' "$d"/*.go 2>/dev/null
done | sort -u | head -20
```

---

## Assembly

Go assembly is written in Go's own assembler syntax, not GNU as, and is per-architecture by construction. Inventory it rather than reviewing it — a hand-written arm64 routine is correct or the tests fail, and it is not reviewable by inspection.

```bash
find . -type d -name .git -prune -o -name '*.s' -print 2>/dev/null \
  | awk -F/ '{f=$NF; a="UNSUFFIXED";
      if (f ~ /_amd64/) a="amd64"; else if (f ~ /_arm64/) a="arm64";
      else if (f ~ /_arm\./) a="arm(32)"; else if (f ~ /_386/) a="386";
      else if (f ~ /_(ppc64|s390x|riscv64|mips|loong64|wasm)/) a="other";
      print a "\t" $0}' | sort | tee graviton-validation/raw/assembly-inventory.txt

awk -F'\t' '{c[$1]++} END {for (k in c) print c[k] "\t" k}' graviton-validation/raw/assembly-inventory.txt
```

What the counts mean:

| Pattern | Reading |
|---|---|
| amd64 and arm64 counts similar | well-ported. Shape A. Nothing to do |
| amd64 count high, arm64 count zero | either Shape B everywhere (fine) or Shape C somewhere (blocker). The `go list` error file decides which |
| arm64 present but fewer files than amd64 | partial port — some routines have an arm64 path, others fall back. Fine, and worth a benchmark note |
| `UNSUFFIXED` non-zero | open each one (Shape C in disguise, variant 1) |
| `other` architectures present | the project already cares about portability. Shape C is unlikely; confirm and move on |

`go vet`'s `asmdecl` check validates assembly function signatures against their Go declarations and is architecture-aware, which makes the Phase 3.1 vet diff a genuine assembly check:

```bash
GOOS=linux GOARCH=arm64 go vet ./... 2>&1 | grep -i asmdecl
```

---

## Build tags projects use for a portable path

When a Shape C blocker lives in a dependency, the cheapest fix is often a tag the dependency already offers. Check before proposing a fork or an upgrade:

| Tag | Convention | Check |
|---|---|---|
| `purego` | the de facto standard for "no assembly, no cgo"; used by `golang.org/x/crypto`-adjacent and many hashing/crypto modules | `grep -rn 'go:build.*purego' "$dir"` |
| `noasm` | same intent, older convention | `grep -rn 'go:build.*noasm' "$dir"` |
| `appengine` | legacy; some modules still use it to mean "portable only" | `grep -rn 'go:build.*appengine' "$dir"` |
| `netgo` / `osusergo` | stdlib: force Go's own resolver and user lookup instead of libc's | not a constraint fix; a cgo behavior choice (see cgo doc) |
| `dynamic` | convention in modules that bundle a C archive, to link the system library instead | Route 3 → Route 2 conversion |
| `lambda.norpc` | `aws-lambda-go`: drops the RPC server, smaller binary. Unrelated to architecture but belongs on the Lambda build line | — |

A tag applies to the **whole build**, including amd64. Adding `-tags purego` to fix arm64 also removes the amd64 assembly path, so the x86 fleet loses the fast path too. Document that; it is often acceptable and must never be silent.

```bash
# Verify a tag actually resolves the blocker before proposing it
GOOS=linux GOARCH=arm64 go build -tags purego ./... 2>&1 | tail -20
# And confirm what it costs on amd64
GOOS=linux GOARCH=amd64 go test -tags purego -bench . -run '^$' ./internal/hash/ 2>&1 | tail
```

---

## x/sys/cpu feature bits on Graviton

When code dispatches on CPU features rather than on `GOARCH`, the constraint question becomes a feature question. `golang.org/x/sys/cpu` exposes both families:

| x86 bit | arm64 counterpart | Present on Graviton2+ |
|---|---|---|
| `cpu.X86.HasSSE2`, `HasSSE41`, `HasAVX`, `HasAVX2` | `cpu.ARM64.HasASIMD` (NEON — the general SIMD unit) | yes |
| `cpu.X86.HasAES` | `cpu.ARM64.HasAES` | yes |
| `cpu.X86.HasPCLMULQDQ` | `cpu.ARM64.HasPMULL` | yes |
| `cpu.X86.HasSHA` | `cpu.ARM64.HasSHA1`, `HasSHA2` | yes |
| `cpu.X86.HasPOPCNT` | always available in the base ISA | n/a |
| (no direct analogue) | `cpu.ARM64.HasATOMICS` (LSE atomics) | yes |
| `cpu.X86.HasAVX512*` | `cpu.ARM64.HasSVE` / `HasSVE2` | generation-dependent — **read the bit** |

The `HasSVE` row is why the rule is to read the bit rather than assume. SVE availability differs across Graviton generations, so code that hardcodes "Graviton has SVE" is wrong on some of the fleet while code that reads `cpu.ARM64.HasSVE` is correct on all of it.

The finding in this area is never the `if`; it is the `else`:

```bash
# Files reading x86 bits, and whether they read any arm64 bit at all
grep -rl --include='*.go' 'cpu\.X86\.' . --exclude-dir=vendor 2>/dev/null \
  | while read -r f; do grep -q 'cpu\.ARM64\.' "$f" || echo "X86-ONLY DISPATCH: $f"; done
```

An `X86-ONLY DISPATCH` file is fine if its final branch is a correct generic implementation, and a finding if that branch errors, panics or disables the feature. Read it.

---

## False verdicts

| False verdict | Why it is wrong | The real check |
|---|---|---|
| "No `//go:build amd64` lines, so no constraint problem" | the filename suffix is a constraint with no line in the file | `find` for `*_amd64.*`, plus `go list`'s `IgnoredGoFiles` |
| "`go build ./...` passed, so there is no Shape C" | **measured:** `./...` silently skips a package nothing imports. With an unimported `//go:build amd64`-only directory, `go list ./...`, `go list -deps -json ./...`, `go build ./...` and `go vet ./...` all reported 0 errors on arm64 | the per-directory sweep (Pass 2), diffed against the amd64 sweep |
| "`CgoFiles` was empty, so the package has no cgo" | **measured:** with `CGO_ENABLED=0`, `go list` moves cgo files into `IgnoredGoFiles` and reports `Cgo=[]` | re-capture with `CGO_ENABLED=1`, and grep `IgnoredGoFiles` for `cgo` as a guard |
| "I widened the `//go:build` line, so it is fixed" | the filename suffix overrides it | rename the file as well |
| "`_arm.go` exists, so it is ported" | `GOARCH=arm` is 32-bit ARM, excluded on arm64 | look for `arm64` specifically |
| "There is a generic fallback, so it works" | the fallback can be a stub, a zero return or a panic | read the body |
| "The tests pass, so the generic path is fine" | the test file may be gated on amd64, leaving the generic path uncovered | `grep` the test files' constraints |
| "N amd64 files means N problems" | most are Shape B and need nothing | classify by shape, using the `go list` error file |
| "`vendor/` is dependency code, skip it" | vendored amd64-only assembly compiles into your binary | scan `vendor/` |
| "I patched `vendor/`, so it is fixed" | the next `go mod vendor` silently reverts it | upgrade, `replace`, or use a tag |
| "`-tags purego` fixed it" (applied silently) | the tag changes amd64's build too, removing its fast path | document the global effect |
| "An unsuffixed `.s` file is architecture-neutral" | it is compiled for **every** architecture unless it says otherwise | open it and check for a `//go:build` line |
