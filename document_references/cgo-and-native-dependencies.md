# cgo and Native Dependencies — Evidence Standard

The evidence standard for every verdict in `02-cgo-report.md`. Read during Phase 1.2 and whenever a cgo verdict needs backing.

## Contents

- [Why cgo is the whole question](#why-cgo-is-the-whole-question)
- [The four routes a C library takes into a Go build](#the-four-routes-a-c-library-takes-into-a-go-build)
- [Establishing which route applies](#establishing-which-route-applies)
- [Route 1: vendored C source](#route-1-vendored-c-source)
- [Route 2: system library](#route-2-system-library)
- [Route 3: bundled prebuilt archive](#route-3-bundled-prebuilt-archive)
- [Route 4: downloaded at build time](#route-4-downloaded-at-build-time)
- [Commonly-hit modules and the question to ask](#commonly-hit-modules-and-the-question-to-ask)
- [Cross-compiling cgo](#cross-compiling-cgo)
- [glibc, musl and static linking](#glibc-musl-and-static-linking)
- [The CGO_ENABLED escape hatch and what it costs](#the-cgo_enabled-escape-hatch-and-what-it-costs)
- [False verdicts](#false-verdicts)

---

## Why cgo is the whole question

A pure-Go module migrates to Graviton with a build flag. A module with required cgo migrates at the speed of its C dependencies. Nothing else in this skill changes the shape of the project as much, which is why Phase 1.2 runs before everything except project structure.

The split is binary and one command establishes it:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./... && echo "CGO-OPTIONAL or PURE GO" || echo "CGO-REQUIRED"
```

Run it before analysing anything. If it succeeds, most of this document is informational.

> **Do not let `CGO_ENABLED` leak into the inventory.** The command above deliberately
> sets `CGO_ENABLED=0` to ask one question. The Phase 1.2 inventory must be captured with
> `CGO_ENABLED=1`, because `go list` populates `CgoFiles` only when cgo is enabled.
> Measured on go1.27.2/linux-arm64 against a package with one `import "C"` file:
>
> ```
> CGO_ENABLED=0 -> Cgo=[]        Ignored=[cgo.go hash_amd64.go]
> CGO_ENABLED=1 -> Cgo=[cgo.go]  Ignored=[hash_amd64.go]
> ```
>
> `go env CGO_ENABLED` is `0` on any host with no C compiler, so an inventory that
> inherits the environment reports a cgo-heavy project as pure Go and the hardest part
> of the migration never appears in the report.

---

## The four routes a C library takes into a Go build

The arm64 question has a completely different answer per route, and conflating them is the main source of wrong verdicts:

| Route | How the library arrives | The arm64 question | Typical fix |
|---|---|---|---|
| **1. Vendored C source** | `.c`/`.h` files inside the Go module, compiled by cgo on every build | **none.** C source compiles for whatever the compiler targets | ensure a C compiler exists in the arm64 builder |
| **2. System library** | `-lfoo` in `LDFLAGS`, or `pkg-config` | does the target distro publish `libfoo` for aarch64? | install the aarch64 package |
| **3. Bundled prebuilt archive** | a committed `.a`/`.so` inside the module, usually per-platform | does **this version** bundle an arm64 archive? | upgrade to a version that does, or switch to dynamic linking |
| **4. Downloaded at build time** | `curl`/`wget` in a Makefile, `go:generate` or Dockerfile | does the download URL have an arm64 variant? | make the URL architecture-aware |

Route 1 is the most common and the least troublesome — most "cgo dependencies" in the Go ecosystem are a C library's source amalgamated into the module. Route 3 is the one that produces a version-specific answer and therefore the one that justifies a dependency change.

---

## Establishing which route applies

For each package reported by Phase 1.2's `go list` scan, inspect the module in the cache. Everything below is read-only:

```bash
pkg=github.com/example/thing
ver=$(go list -m -f '{{.Version}}' "$pkg" 2>/dev/null)
dir=$(go list -m -f '{{.Dir}}' "$pkg" 2>/dev/null)
echo "$pkg@$ver -> $dir"

# Route 1? C source compiled in-module
find "$dir" -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.h' 2>/dev/null | head -20

# Route 3? prebuilt archives or shared objects shipped in the module
find "$dir" \( -name '*.a' -o -name '*.so' -o -name '*.so.*' -o -name '*.dylib' \) 2>/dev/null

# Route 2? what does cgo ask the linker for
grep -rhn --include='*.go' -E '^//[[:space:]]*#cgo.*(LDFLAGS|pkg-config)' "$dir" 2>/dev/null

# Route 4? a download inside the module's own build steps
grep -rn -E 'go:generate|curl|wget' "$dir" --include='*.go' --include='Makefile' 2>/dev/null | head
```

A module can use more than one route — Route 1 for the core plus Route 2 for an optional codec is common. Record each library separately; the verdict is per library, not per module.

---

## Route 1: vendored C source

**Verdict: no arm64 availability question exists.** The C code compiles for the architecture the C compiler targets. If the compiler can target aarch64, the library builds.

What to verify instead:

```bash
# A C compiler is present in the arm64 build environment
cc --version 2>/dev/null || gcc --version 2>/dev/null || echo "MISSING C COMPILER"

# The C source does not itself contain x86-only code
grep -rn -E '#include <(immintrin|emmintrin|xmmintrin|smmintrin|nmmintrin|wmmintrin|tmmintrin|pmmintrin|x86intrin|cpuid)\.h>' "$dir" 2>/dev/null
grep -rn -E '__SSE|__AVX|__x86_64__|__i386__|_mm_|_mm256_' "$dir" --include='*.c' --include='*.h' 2>/dev/null | head -20
grep -rn -E '\basm\b.*\(|__asm__' "$dir" --include='*.c' --include='*.h' 2>/dev/null | head
```

**Measured, so the method is not theoretical.** `confluent-kafka-go/v2` at v2.0.2,
v2.1.1, v2.3.0, v2.5.3 and v2.12.0 each bundle the same **seven** archives under
`kafka/librdkafka_vendor/`:

```
librdkafka_darwin_amd64.a      librdkafka_glibc_linux_amd64.a   librdkafka_musl_linux_amd64.a
librdkafka_darwin_arm64.a      librdkafka_glibc_linux_arm64.a   librdkafka_musl_linux_arm64.a
librdkafka_windows.a
```

Three things that listing says out loud:

1. **No arm64 version floor exists in the v2 line** - every version tested has it. An
   upgrade "for arm64 support" on this module would therefore be scope creep, and the
   correct verdict is `BUNDLED-OK`. This is precisely why no version floors are asserted
   anywhere in this skill: the check costs seconds, and a recalled floor would have been
   wrong here.
2. The archive name encodes the **C library** as well as the architecture, so the
   glibc-vs-musl row in Phase 1.1's table is a real selection and not a footnote.
3. It built and ran on a `c7g.2xlarge`: `librdkafka=0x20c00ff (2.12.0)`.

Three outcomes:

- **no hits** → PASS. The library is portable C and builds on aarch64
- **hits inside `#ifdef __x86_64__` / `#if defined(__SSE2__)` with an `#else`** → PASS. Properly guarded; the portable branch compiles on aarch64. **Read the `#else`** — confirm it exists and is an implementation, not an `#error`
- **unguarded x86 intrinsics or inline asm** → the library does not build on aarch64 as vendored. Check upstream for a newer release with aarch64 support (many C libraries gained NEON paths years after SSE ones), which converts this into a Route-3-style version decision

The frequent trap in this route is the builder image: `golang:1.x-alpine` and `golang:1.x-bullseye-slim` ship without a C compiler, so a module that built fine on a developer's machine fails in CI with `C compiler "gcc" not found`. That is an environment fix (`apk add build-base`, `apt-get install build-essential`), not a dependency fix, and it is **not architecture-specific** — it will have been failing on x86 too if the image is the same.

---

## Route 2: system library

**Verdict depends on the target distribution's aarch64 repository**, and must be established against the specific image the deployment uses, not against "Linux".

Read the exact library names cgo asks for:

```bash
grep -rhn --include='*.go' -E '^//[[:space:]]*#cgo' "$dir" | grep -E 'LDFLAGS|pkg-config'
# e.g.  #cgo LDFLAGS: -lzstd -lsnappy
#       #cgo pkg-config: libsodium
```

Then query the target's aarch64 index. Both commands below run for the host's own platform — no emulation, so they work from an x86 laptop and finish in seconds:

```bash
# Debian / Ubuntu: read arm64 from ports.ubuntu.com (the amd64 mirrors carry no arm64 files;
# apt-get update against them reports "binary-arm64/Packages 404 Not Found")
timeout 300 docker run --rm ubuntu:24.04 sh -c '
  echo "deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports noble main universe multiverse" \
    > /etc/apt/sources.list.d/arm64.list
  sed -i "s|^deb |deb [arch=amd64] |" /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
  dpkg --add-architecture arm64
  apt-get update -qq 2>/dev/null
  for p in libzstd-dev libsnappy-dev; do printf "%s: " "$p"; apt-cache policy "$p:arm64" | sed -n 2p; done'

# Amazon Linux 2023 / dnf distributions
timeout 300 docker run --rm amazonlinux:2023 sh -c '
  for p in libzstd-devel snappy-devel; do printf "%s: " "$p"; \
    dnf -q --forcearch=aarch64 list available "$p" 2>/dev/null | tail -1; done'

# Alpine (musl): note this is a DIFFERENT C library as well as a different architecture
timeout 300 docker run --rm alpine:3.20 sh -c \
  'apk update -q && for p in zstd-dev snappy-dev; do printf "%s: " "$p"; apk policy "$p" | sed -n 2p; done'
```

Record the evidence line verbatim in `02-cgo-report.md`. A package that exists for aarch64 in the target's repository is a `PASS` with a citation; one that does not is `NEEDS AARCH64 BUILD` escalating to `BLOCKER` if no source build is viable either.

Both the **builder** and the **runtime** environment need the library — the builder needs the `-dev`/`-devel` package for headers, the runtime needs the shared library unless the binary is statically linked. Checking only the builder produces a build that passes and a container that will not start.

---

## Route 3: bundled prebuilt archive

**This is the only route where the dependency's version number is the answer**, and therefore the only route where `go get` is a legitimate fix.

The verdict is a directory listing. Do not infer it from a changelog, a release note, or a recollection of when arm64 support landed:

```bash
mod=github.com/example/thing
for ver in v1.8.2 v1.9.0 v2.0.0 v2.3.0; do
  GOFLAGS=-mod=mod go mod download "$mod@$ver" 2>/dev/null || { echo "$ver: download failed"; continue; }
  d="$(go env GOMODCACHE)/$(echo "$mod" | tr 'A-Z' '!a-z')@$ver"
  echo "=== $ver ==="
  find "$d" \( -name '*.a' -o -name '*.so' -o -name '*.so.*' \) 2>/dev/null | sed "s|$d/||" | sort
done
```

Module cache paths lowercase-escape capital letters (`!` prefix), which the `tr` above approximates; if the path does not resolve, get it authoritatively:

```bash
go list -m -f '{{.Dir}}' "$mod@$ver"
```

Judge each archive by content, not by name:

```bash
a=/path/to/librdkafka_glibc_linux_arm64.a
file -b "$a"                                    # "current ar archive" - no architecture yet
m=$(ar t "$a" | head -1)
ar p "$a" "$m" > /tmp/m.o && file -b /tmp/m.o && rm -f /tmp/m.o
# Expect: ELF 64-bit LSB relocatable, ARM aarch64
```

Three outcomes:

- an arm64 archive exists in the current version → `BUNDLED-OK`. Quote the file name. No change
- an arm64 archive exists in a newer version → `MUST UPGRADE` to the **lowest** version that has it. Quote the file name and the version. This is in scope
- no version bundles one → check whether the module offers a dynamic-linking build tag, which converts the problem into Route 2:
  ```bash
  grep -rn -E '^//[[:space:]]*(go:build|\+build).*(dynamic|system)' "$dir" --include='*.go' | head
  ```
  A dynamic tag is a user decision: it moves the library out of the binary and into the deployment image, which changes how the service is packaged. **Measured** - on a c7g.2xlarge with librdkafka not installed, `go build -tags dynamic` fails with:

  ```
  # github.com/confluentinc/confluent-kafka-go/v2/kafka
  # [pkg-config --cflags  -- rdkafka]
  Package rdkafka was not found in the pkg-config search path.
  Package 'rdkafka', required by 'virtual:world', not found
  ```

  That error IS the conversion: the module stopped carrying its own library and now asks
  the system for one, which is Route 2's problem with Route 2's fix

A bundled archive also carries a **C library** and a **glibc version**, not just an architecture. An archive named `_glibc_` will not load on alpine; one built against a newer glibc than the runtime image provides will not load there either. Grade it against the libc table in Phase 1.1.

---

## Route 4: downloaded at build time

The arm64 question is whether the upstream publishes an arm64 asset, and the evidence is the release listing:

```bash
# GitHub releases: list the asset names for the pinned tag
curl -fsS "https://api.github.com/repos/<owner>/<repo>/releases/tags/<tag>" \
  | python3 -c 'import json,sys; [print(a["name"]) for a in json.load(sys.stdin).get("assets",[])]'
```

Then make the download architecture-aware (Phase 2.3). Two naming vocabularies collide here and getting them backwards is a common bug:

| Source | x86 name | arm64 name |
|---|---|---|
| Go (`GOARCH`), Docker (`TARGETARCH`), most release assets | `amd64` | `arm64` |
| `uname -m` | `x86_64` | `aarch64` |
| Some release assets (notably from C projects) | `x86_64` | `aarch64` |
| **`protoc`** (protocolbuffers/protobuf releases) | `x86_64` | **`aarch_64`** |

The `protoc` row is measured, not inferred: the v36.2 release publishes
`protoc-36.2-linux-aarch_64.zip` and `protoc-36.2-linux-x86_64.zip`. Neither `arm64` nor
`aarch64` appears, and `protoc` is one of the most commonly fetched tools in a Go
repository. A third vocabulary is why the rule is to **list the assets** rather than
construct the name:

```bash
curl -fsS "https://api.github.com/repos/protocolbuffers/protobuf/releases/tags/v36.2" \
  | python3 -c 'import json,sys; [print(a["name"]) for a in json.load(sys.stdin)["assets"]]' \
  | grep -i linux
```

So a script that does `ARCH=$(uname -m)` and interpolates it into a URL expecting `amd64`/`arm64` is broken on **both** architectures; one that hardcodes `amd64` is broken only on arm64 and therefore survived until now. Always map explicitly, with a failing default branch.

---

## Commonly-hit modules and the question to ask

**No version floors are asserted in this table.** A floor changes with every release and a recalled floor is a wrong verdict waiting to happen — run the Route 3 or Route 2 check for the version the project actually pins. The table gives the route and the shape of the check, which is the part that does not go stale.

| Module | Route | The check to run |
|---|---|---|
| `mattn/go-sqlite3` | 1 (amalgamated SQLite C source) | C compiler present in the arm64 builder. Then it just compiles |
| `confluentinc/confluent-kafka-go` | 3 (bundled librdkafka archives, named `librdkafka_<libc>_<os>_<arch>.a`) | list the `.a` files in the pinned version's module dir; look for an `arm64` one. Also check whether the pinned version supports `-tags dynamic` |
| `DataDog/zstd`, `klauspost/compress` (cgo variants) | 1 | unguarded x86 intrinsics in the vendored C |
| `gographics/imagick`, `h2non/bimg` | 2 (ImageMagick / libvips) | aarch64 `-dev` package in the target distro, in builder **and** runtime |
| `hybridgroup/gocv` | 2 (OpenCV) | aarch64 OpenCV availability; often a source build either way |
| `godror/godror`, `mattn/go-oci8` | 2 (Oracle Instant Client) | does the vendor publish an aarch64 Instant Client for the target OS |
| `rogchap/v8go` | 3 (bundled V8 static libs) | arm64 archive in the pinned version |
| `tensorflow/tensorflow` Go bindings, `yalue/onnxruntime_go` | 2/4 (downloaded shared libs) | aarch64 asset in the release listing |
| `go-ldap`, `go-sasl` with cgo backends | 2 | aarch64 `libsasl2`/`libldap` packages |
| `prometheus/procfs`, `shirou/gopsutil` | pure Go or Route 1, with arch-constrained files | treat as a Phase 1.3 build-constraint question, not a cgo one |
| `golang.org/x/sys` | pure Go with heavy per-arch files | Shape A everywhere; never a finding. Just keep it resolvable |

Two modules worth a note for their pure-Go alternatives, offered as a user decision and never applied unilaterally:

- `mattn/go-sqlite3` → `modernc.org/sqlite` (pure Go, no cgo at all). Different implementation, different performance profile, different failure modes
- `confluent-kafka-go` → `IBM/sarama` or `segmentio/kafka-go` (pure Go). Different feature coverage, notably around transactions and the exactly-once semantics librdkafka provides

---

## Cross-compiling cgo

Pure Go cross-compiles with nothing but environment variables. cgo needs a cross C toolchain, and the setup is per target libc:

**The cross toolchain is not available everywhere.** Measured: `dnf install
gcc-aarch64-linux-gnu` finds no such package on Amazon Linux 2023, so an AL2023 build
host cannot cross-compile cgo without building a toolchain first. On a Debian or Ubuntu
host it is one package. That asymmetry is a concrete reason to prefer a native arm64
builder, below.

```bash
# Debian/Ubuntu build host, targeting linux/arm64 glibc
sudo apt-get install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu

CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
  CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ \
  go build -o app-arm64 ./cmd/app

file -b app-arm64     # expect: ELF 64-bit LSB ... ARM aarch64
```

Without `CC`, the failure is loud but misleading. Measured on an x86 host:

```
# runtime/cgo
gcc_arm64.S: Assembler messages:
gcc_arm64.S:30: Error: no such instruction: `stp x29,x30,[sp,'
gcc_arm64.S:34: Error: operand size mismatch for `mov'
```

The host's x86 gcc was handed arm64 assembly from `runtime/cgo`. It reads like a Go
runtime bug; it is a missing cross-compiler.

This works only when **every** C library the build links is also available as an aarch64 build on the build host — headers and libraries both, under the cross sysroot. For one vendored C library that is easy; for three system libraries it is usually more work than provisioning an arm64 builder.

**The default recommendation when cgo is required: build natively on arm64.** A Graviton CI runner or a `ubuntu-24.04-arm` GitHub runner removes the entire cross-toolchain problem, and the build is faster than emulation by an order of magnitude. Cross-compiling cgo is the right answer when you cannot get an arm64 builder, not the first thing to try.

Musl targets need a musl cross-toolchain, not the glibc one:

```bash
# Targeting alpine/musl on arm64 - the glibc cross-compiler produces a binary that will not load
CC=aarch64-linux-musl-gcc CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go build ...
```

---

## glibc, musl and static linking

A cgo binary's portability is bounded by three things, all independent of architecture and all commonly discovered during a migration:

1. **C library family.** glibc and musl are not interchangeable. A glibc-linked binary in an alpine image fails with `/lib/ld-musl-aarch64.so.1: not found`; the reverse fails differently. Both are architecture-independent failures that look architecture-related because they appear for the first time during the migration
2. **glibc version.** A binary built against glibc 2.39 (Ubuntu 24.04) does not run on glibc 2.34 (Amazon Linux 2023). Build against the **oldest** glibc in the deployment fleet, or match the runtime image exactly
3. **Static vs dynamic.** `scratch` and `distroless/static` runtime images require a fully static binary:
   ```bash
   CGO_ENABLED=1 GOOS=linux GOARCH=arm64 \
     go build -ldflags '-extldflags "-static"' -tags 'netgo osusergo' -o app ./cmd/app
   file -b app     # expect "statically linked"
   ldd app         # expect "not a dynamic executable"
   ```
   Note the `netgo osusergo` tags: a static glibc build with the system resolver is a known-broken combination (glibc's NSS loads shared objects at run time, which a static binary cannot do), so static cgo binaries must use Go's own resolver. That is a behavior change — see Phase 2.5

---

## The `CGO_ENABLED` escape hatch and what it costs

When a cgo link error blocks the arm64 build, setting `CGO_ENABLED=0` makes it disappear. It is the single most tempting move in this transformation and it is only correct when the deployment also sets it.

What changes, all of it independent of architecture:

| Area | `CGO_ENABLED=1` (with a C toolchain) | `CGO_ENABLED=0` |
|---|---|---|
| `net` name resolution | may use the system resolver (`getaddrinfo`), honoring `/etc/nsswitch.conf` and NSS modules (LDAP, SSSD, mDNS) | Go's own resolver: reads `/etc/resolv.conf` directly, **ignores NSS** |
| `os/user` lookups | may use libc `getpwnam`/`getgrnam`, honoring NSS | reads `/etc/passwd` and `/etc/group` directly |
| `go test -race` | available | **the race detector requires cgo; `-race` will not build** |
| Any required cgo package | links | build fails — which is the honest outcome, and better than a silent behavior change |
| Binary | dynamically linked by default | static by default |

The race-detector row is the one that bites this skill directly: turning cgo off to fix the build also disables exit criterion 9. If the deployment genuinely runs `CGO_ENABLED=0`, build the **test** binary with cgo enabled for the race run specifically, and say so in the report.

If this transformation changes `CGO_ENABLED`, it is a documented behavior change requiring user confirmation (Phase 2.5), not a build fix.

---

## False verdicts

Each of these has produced a wrong answer in practice:

| False verdict | Why it is wrong | The real check |
|---|---|---|
| "This module uses cgo" (from grepping `import "C"`) | the file may be excluded by a build constraint, or the package may not be in the resolved set at all | `go list -deps -json` reporting non-empty `CgoFiles` |
| "This module does not use cgo" (from grepping and finding nothing) | cgo can arrive through a transitive dependency you never named | the same `go list` scan, over `-deps` |
| "`go list` reported no `CgoFiles`, so the project is pure Go" | **measured:** `CgoFiles` is populated only when cgo is enabled. With `CGO_ENABLED=0` the same files appear in `IgnoredGoFiles` and the package looks pure — and `go env CGO_ENABLED` is `0` on any host without a C compiler, so an inherited-environment capture reports a cgo project as pure | capture with `CGO_ENABLED=1` explicitly, and grep `IgnoredGoFiles` for `cgo` before trusting a zero |
| "libfoo supports arm64" (from the project's website) | the question is whether the **target distro** packages it, at a version the build can use | the distro index query in Route 2 |
| "Version X added arm64 support" (from a changelog) | the bundle contents are the fact; a changelog can describe a platform that was added then dropped, or added for darwin only | the `find`/`ar`/`file` sequence in Route 3 |
| "`file` says it is an ar archive, so it is fine" | `.a` files report no architecture | extract a member and run `file` on it |
| "The arm64 build succeeded, so cgo is fine" | it succeeded on the build host; the runtime image may have a different libc or glibc version | `ldd` on the binary inside the runtime image (Phase 3.4) |
| "`CGO_ENABLED=0` fixed it" | it changed the program's resolver and user-lookup behavior and disabled `-race` | confirm the deployment's own `CGO_ENABLED`; if it is `1`, this is not a fix |
| "`build constraints exclude all Go files` means Shape C" | **measured**: a package whose files are ALL cgo files emits that exact message under `CGO_ENABLED=0`. With `CGO_ENABLED=1` the same package reports `CgoFiles=[main.go] Ignored=[]` | re-resolve that one package with `CGO_ENABLED=1 go list <dir>`. If it succeeds, the fix is Phase 2.1, not 2.2 |
| "cgo files land in `IgnoredGoFiles` when cgo is off, so that is the guard" | **measured**: true only for a MIXED package (`GoFiles=[plain.go] CgoFiles=[] Ignored=[only_cgo.go]`). A package with no non-cgo file does not resolve at all | use both signals: `IgnoredGoFiles` for mixed packages, the resolution error for pure-cgo ones |
| "The image is arm64, so the binary is" | `--platform` sets the image's declared architecture; `GOARCH` sets the binary's | `file` on the binary extracted from the image (Phase 3.3) |
| "No arm64 package, so this is a blocker" | a source build may be entirely viable, and often is for a small C library | try the source build before escalating to a user decision |
