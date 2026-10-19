#!/usr/bin/env bash
# go_arch_scan.sh - read-only arm64 readiness scan for a Go project.
#
# Covers the deterministic parts of Phase 1: cgo inventory, build constraints and
# assembly, committed native artifacts, and architecture selection in build scripts
# and deployment descriptors.
#
# READ-ONLY. It never writes inside the scanned tree and never runs the project's
# own build. With the Go toolchain available it uses `go list` as the fact base;
# without it, it falls back to a grep-only mode in which every verdict is CHECK.
#
# Usage:
#   ./go_arch_scan.sh [PROJECT_DIR] [-o OUTPUT_DIR]
#
# Exit status:
#   0  no blocking findings
#   1  findings present
#   2  not a Go project / no input
#
# Compatible with bash 3.2 (macOS default) and later.

set -u

PROJECT="${1:-.}"
case "$PROJECT" in -*) PROJECT="." ;; *) [ $# -gt 0 ] && shift ;; esac
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) shift ;;
  esac
done

[ -d "$PROJECT" ] || { echo "not a directory: $PROJECT" >&2; exit 2; }
cd "$PROJECT" || exit 2
[ -f go.mod ] || [ -f go.work ] || {
  echo "no go.mod or go.work in $(pwd): not a Go project" >&2; exit 2; }

FINDINGS=0
CHECKS=0
note()    { printf '%s\n' "$*"; }
head2()   { printf '\n== %s ==\n' "$*"; }
finding() { FINDINGS=$((FINDINGS+1)); printf 'FINDING  %s\n' "$*"; }
check()   { CHECKS=$((CHECKS+1));     printf 'CHECK    %s\n' "$*"; }
ok()      { printf 'OK       %s\n' "$*"; }

HAVE_GO=0
command -v go >/dev/null 2>&1 && HAVE_GO=1
HAVE_FILE=0
command -v file >/dev/null 2>&1 && HAVE_FILE=1

# Go's own GOOS and GOARCH value lists. A filename suffix drawn from either list IS a
# build constraint, with no marker inside the file - so these drive every "is this file
# constrained" decision below. Omitting the GOOS list is how `futimens_darwin.s` and
# `bpxsvc_zos.s` get reported as unconstrained when the filename already constrains them.
GOOS_RE='aix|android|darwin|dragonfly|freebsd|hurd|illumos|ios|js|linux|nacl|netbsd|openbsd|plan9|solaris|wasip1|windows|zos'
NON_LINUX_GOOS_RE='aix|android|darwin|dragonfly|freebsd|hurd|illumos|ios|js|nacl|netbsd|openbsd|plan9|solaris|wasip1|windows|zos'
GOARCH_RE='386|amd64|amd64p32|arm|arm64|arm64be|armbe|loong64|mips|mips64|mips64le|mips64p32|mips64p32le|mipsle|mipsx|mips64x|ppc|ppc64|ppc64le|ppc64x|riscv|riscv64|s390|s390x|sparc|sparc64|wasm'

# has_build_constraint FILE - true when the file carries a //go:build or // +build line.
#
# The constraint may appear ANYWHERE in the leading comment block, not just at the top:
# measured on containerd's vendor tree, github.com/petermattis/goid/goid_go1.4.s carries
# it at line 8 and goid_go1.5.s at line 18, both behind a license header. A `head -5`
# check reports both as unconstrained, which is a false FINDING on correct code.
# Scan until the first line that is neither blank nor a comment, capped at 200 lines.
has_build_constraint() {
  awk '
    /^[[:space:]]*\/\/[[:space:]]*(go:build|\+build)/ { found=1; exit }
    /^[[:space:]]*$/                                 { next }
    /^[[:space:]]*\/\//                              { next }
    /^[[:space:]]*\/\*/                              { inblock=1; next }
    inblock && /\*\//                                { inblock=0; next }
    inblock                                          { next }
    { exit }                 # first real line of code: no constraint before it
    NR > 200                 { exit }
    END { exit !found }
  ' "$1" 2>/dev/null
}

note "go_arch_scan - $(pwd)"
note "toolchain: $([ $HAVE_GO -eq 1 ] && go version 2>/dev/null || echo 'go NOT FOUND - grep-only mode, all verdicts CHECK')"

TMP="${TMPDIR:-/tmp}/go_arch_scan.$$"
mkdir -p "$TMP" || exit 2
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- 1. resolution
head2 "1. Resolution for linux/arm64"
if [ $HAVE_GO -eq 1 ]; then
  # CGO_ENABLED=1 is deliberate: go list populates CgoFiles only when cgo is enabled.
  # With it off, cgo files move to IgnoredGoFiles and a cgo project looks pure Go.
  CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go list -deps -json ./... \
    >"$TMP/deps-arm64.json" 2>"$TMP/deps-arm64.err"
  CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go list -deps -json ./... \
    >"$TMP/deps-amd64.json" 2>"$TMP/deps-amd64.err"

  # STEP 1 - did the capture actually succeed? Nothing below may claim a verdict until
  # this is answered. A failed capture produces an empty .json and an .err full of
  # environment complaints, and reading "no findings" out of that is how an empty
  # result becomes a false all-clear.
  npkg=$(grep -c '"ImportPath"' "$TMP/deps-arm64.json" 2>/dev/null)
  npkg=${npkg:-0}; [ "$npkg" -eq "$npkg" ] 2>/dev/null || npkg=0

  if [ "$npkg" -eq 0 ]; then
    check "go list resolved 0 packages - RESOLUTION FAILED. No Shape C verdict is possible;"
    note  "           every verdict below is CHECK, including the ones that print OK."
    # Name the cause rather than leaving the user to guess. These are the four that
    # actually happen, and three of them are environment rather than code.
    if grep -qE 'GOCACHE is not defined|neither \$XDG_CACHE_HOME nor \$HOME|module cache not found|neither GOMODCACHE nor GOPATH' "$TMP/deps-arm64.err" 2>/dev/null; then
      note "           cause: no HOME/GOCACHE/GOMODCACHE in this environment (common under"
      note "                  CI runners, sudo, SSM Run Command and container entrypoints)."
      note "           fix:   export HOME=/root GOCACHE=\$HOME/.cache/go-build GOMODCACHE=\$HOME/go/pkg/mod"
    elif grep -qE 'missing go.sum entry|no required module provides|module .* found .* but does not contain' "$TMP/deps-arm64.err" 2>/dev/null; then
      note "           cause: dependencies not downloaded."
      note "           fix:   go mod download   (or use the committed vendor/ with -mod=vendor)"
    elif grep -qE 'dial tcp|i/o timeout|proxy.golang.org|certificate|410 Gone' "$TMP/deps-arm64.err" 2>/dev/null; then
      note "           cause: the module proxy is unreachable."
      note "           fix:   provide proxy access, or scan a checkout that has vendor/"
    elif grep -qE 'unrecognized import path|terminal prompts disabled|authentication required' "$TMP/deps-arm64.err" 2>/dev/null; then
      note "           cause: a private module cannot be resolved."
      note "           fix:   set GOPRIVATE and the host's credentials, or scan with vendor/"
    fi
    note "           raw stderr (first 6 lines):"
    sed 's/^/             /' "$TMP/deps-arm64.err" 2>/dev/null | head -6
    HAVE_GO=0
  else
    ok "resolved $npkg packages for linux/arm64"

    # STEP 2 - Shape C reachable through an import: blocks the build today.
    n=$(grep -c 'build constraints exclude all Go files' "$TMP/deps-arm64.err" 2>/dev/null)
    n=${n:-0}; [ "$n" -eq "$n" ] 2>/dev/null || n=0
    if [ "$n" -gt 0 ]; then
      grep 'build constraints exclude all Go files' "$TMP/deps-arm64.err" \
        | sed 's/^/FINDING  Shape C (reachable, blocks the build): /'
      FINDINGS=$((FINDINGS+n))
    else
      ok "no reachable Shape C package (go list -deps for arm64)"
    fi

    # STEP 3 - every directory named explicitly. Measured: ./... silently skips a package
    # nothing imports, in go list, go build AND go vet - so step 2 alone misses latent blockers.
    : >"$TMP/sweep-arm64.err"; : >"$TMP/sweep-amd64.err"
    find . -name '*.go' -not -path './.git/*' 2>/dev/null | sed 's|/[^/]*$||' | sort -u \
      | while read -r d; do
          CGO_ENABLED=1 GOOS=linux GOARCH=arm64 go list "$d" >/dev/null 2>>"$TMP/sweep-arm64.err"
          CGO_ENABLED=1 GOOS=linux GOARCH=amd64 go list "$d" >/dev/null 2>>"$TMP/sweep-amd64.err"
        done
    grep 'build constraints exclude all Go files' "$TMP/sweep-arm64.err" 2>/dev/null \
      | sed 's|.*exclude all Go files in ||' | sort -u >"$TMP/sweep-arm64.dirs"
    grep 'build constraints exclude all Go files' "$TMP/sweep-amd64.err" 2>/dev/null \
      | sed 's|.*exclude all Go files in ||' | sort -u >"$TMP/sweep-amd64.dirs"
    comm -23 "$TMP/sweep-arm64.dirs" "$TMP/sweep-amd64.dirs" 2>/dev/null \
      | grep -vE "/($NON_LINUX_GOOS_RE)(/|$)" >"$TMP/sweep-only.dirs"
    ns=$(wc -l <"$TMP/sweep-only.dirs" | tr -d ' ')
    if [ "${ns:-0}" -gt 0 ]; then
      sed 's|^|FINDING  Shape C (arm64-only exclusion; latent until imported): |' "$TMP/sweep-only.dirs"
      FINDINGS=$((FINDINGS+ns))
    else
      ok "per-directory sweep: no arm64-only package exclusions"
    fi

    # Any other arm64-only resolution error
    if [ -s "$TMP/deps-arm64.err" ] && [ ! -s "$TMP/deps-amd64.err" ]; then
      check "arm64 resolution produced errors that amd64 did not; read them:"
      sed 's/^/           /' "$TMP/deps-arm64.err" | head -10
    fi
  fi
else
  check "no Go toolchain: resolution and Shape C detection not verified"
fi

# ---------------------------------------------------------------------- 2. cgo
head2 "2. cgo"
if [ $HAVE_GO -eq 1 ] && command -v python3 >/dev/null 2>&1; then
  python3 - "$TMP/deps-arm64.json" >"$TMP/cgo.txt" 2>/dev/null <<'PY'
import json, sys
dec = json.JSONDecoder()
try:
    buf = open(sys.argv[1]).read()
except OSError:
    sys.exit(0)
i, n = 0, len(buf)
while i < n:
    while i < n and buf[i] in " \t\r\n":
        i += 1
    if i >= n:
        break
    try:
        obj, i = dec.raw_decode(buf, i)
    except ValueError:
        break
    if not (obj.get("CgoFiles") or []):
        continue
    if obj.get("Standard"):          # runtime/cgo, net, os/user: stdlib, never the finding
        continue
    ld = " ".join(obj.get("CgoLDFLAGS") or [])
    cf = " ".join(obj.get("CgoCFLAGS") or [])
    pc = " ".join(obj.get("CgoPkgConfig") or [])
    print("%s\tfiles=%d\tLDFLAGS=[%s]\tCFLAGS=[%s]\tpkgconfig=[%s]"
          % (obj["ImportPath"], len(obj["CgoFiles"]), ld, cf, pc))
PY
  ncgo=$(wc -l <"$TMP/cgo.txt" 2>/dev/null | tr -d ' ')
  if [ "${ncgo:-0}" -eq 0 ]; then
    # Guard the zero: cgo files hiding in IgnoredGoFiles mean the capture had cgo off
    if grep -o '"IgnoredGoFiles":\[[^]]*\]' "$TMP/deps-arm64.json" 2>/dev/null | grep -q 'cgo'; then
      check "CgoFiles is empty BUT cgo files appear in IgnoredGoFiles - the capture did not have cgo enabled. Re-capture with CGO_ENABLED=1."
    else
      ok "no package in the resolved set uses cgo (pure Go: cross-compiles without a C toolchain)"
    fi
  else
    check "$ncgo package(s) use cgo - resolve each C library's route per cgo-and-native-dependencies.md"
    sed 's/^/           /' "$TMP/cgo.txt"
  fi
else
  if grep -rq --include='*.go' 'import "C"' . 2>/dev/null; then
    check "grep found 'import \"C\"'; confirm the package set with CGO_ENABLED=1 go list -deps -json"
  else
    check "cgo not verified (no toolchain); grep found no 'import \"C\"'"
  fi
fi

# x86-only flags in #cgo directives.
# A #cgo line appears either as `// #cgo ...` or bare inside the /* */ block before
# `import "C"` - match both forms, or the block-comment style is missed entirely.
CGO_DIRECTIVE='^[[:space:]]*(//[[:space:]]*)?#cgo[[:space:]]'
X86_FLAG='\-m(64|32|arch=x86|arch=core|arch=native|tune=|sse|avx|aes|popcnt|fma|bmi)'
if grep -rhnE --include='*.go' "$CGO_DIRECTIVE" . 2>/dev/null | grep -qE "$X86_FLAG"; then
  finding "x86-only flags in #cgo directives (make them per-architecture):"
  grep -rnE --include='*.go' "$CGO_DIRECTIVE" . 2>/dev/null \
    | grep -E "$X86_FLAG" | sed 's/^/           /' | head -20
else
  ok "no x86-only flags in #cgo directives"
fi

# ------------------------------------------------------- 3. build constraints
head2 "3. Build constraints and assembly (vendor/ included deliberately)"

# A file whose suffix names a NON-LINUX GOOS is constrained away from this target
# entirely, so it is not an arm64 question: vendor trees are full of _darwin, _windows,
# _plan9 and _zos files and reporting them is pure noise. The same applies to a package
# that lives under a non-linux GOOS directory (golang.org/x/sys/plan9) or under a
# directory named for another architecture (wazero's .../isa/amd64 backend package,
# whose arm64 counterpart is a sibling package, not a sibling file).
irrelevant_path() {
  printf '%s\n' "$1" | grep -qE "/($NON_LINUX_GOOS_RE)/" && return 0
  printf '%s\n' "$1" | grep -qE "_($NON_LINUX_GOOS_RE)(_($GOARCH_RE))?\.(go|s)$" && return 0
  return 1
}

find . -type d -name .git -prune -o -type f \
  \( -name '*_amd64*.go' -o -name '*_amd64*.s' -o -name '*_386*.go' -o -name '*_386*.s' \) \
  -print 2>/dev/null | sort >"$TMP/amd64files.raw"
: >"$TMP/amd64files.txt"
while read -r f; do
  [ -n "$f" ] || continue
  irrelevant_path "$f" || printf '%s\n' "$f" >>"$TMP/amd64files.txt"
done <"$TMP/amd64files.raw"
nskip=$(( $(wc -l <"$TMP/amd64files.raw" | tr -d ' ') - $(wc -l <"$TMP/amd64files.txt" | tr -d ' ') ))

find . -type d -name .git -prune -o -type f \
  \( -name '*_arm64*.go' -o -name '*_arm64*.s' \) -print 2>/dev/null | sort >"$TMP/arm64files.txt"

na=$(wc -l <"$TMP/amd64files.txt" | tr -d ' ')
nr=$(wc -l <"$TMP/arm64files.txt" | tr -d ' ')
note "         amd64/386-suffixed files: $na    arm64-suffixed files: $nr    (skipped $nskip non-linux-GOOS files)"

# Per-directory shape, using the suffix families
if [ "$na" -gt 0 ]; then
  sed 's|/[^/]*$||' "$TMP/amd64files.txt" | sort -u >"$TMP/amd64dirs.raw"
  : >"$TMP/amd64dirs.txt"
  while read -r d; do
    [ -n "$d" ] || continue
    # A package directory literally named for another architecture is that
    # architecture's implementation package; its arm64 peer is a sibling DIRECTORY.
    base=$(basename "$d")
    printf '%s\n' "$base" | grep -qE "^($GOARCH_RE)$" && {
      printf 'OK       arch-specific package dir (peer lives beside it, not inside): %s\n' "$d"
      continue
    }
    printf '%s\n' "$d" >>"$TMP/amd64dirs.txt"
  done <"$TMP/amd64dirs.raw"

  while read -r d; do
    [ -n "$d" ] || continue
    has_arm64=0; has_fallback=0
    ls "$d" 2>/dev/null | grep -q 'arm64' && has_arm64=1
    # A fallback is a file in the same directory gated on !amd64, or named generic/purego/noasm
    ls "$d" 2>/dev/null | grep -qE '_(generic|purego|noasm|portable|other|fallback)[^.]*\.(go|s)$' && has_fallback=1
    grep -lsE '^//[[:space:]]*(go:build|\+build)[^\n]*!amd64' "$d"/*.go >/dev/null 2>&1 && has_fallback=1
    if [ $has_arm64 -eq 1 ]; then
      printf 'OK       Shape A (ported): %s\n' "$d"
    elif [ $has_fallback -eq 1 ]; then
      printf 'CHECK    Shape B (builds, read the fallback body): %s\n' "$d"
      CHECKS=$((CHECKS+1))
    else
      printf 'CHECK    Shape B or C - no arm64 sibling and no obvious fallback: %s\n' "$d"
      CHECKS=$((CHECKS+1))
    fi
  done <"$TMP/amd64dirs.txt"
  note "         (Shape C is confirmed only by 'build constraints exclude all Go files' in section 1)"
fi

# Files constrained to 32-bit arm with no arm64 sibling: looks ported, is not
find . -type d -name .git -prune -o -type f \( -name '*_arm.go' -o -name '*_arm.s' \) -print 2>/dev/null \
  | while read -r f; do
      irrelevant_path "$f" && continue
      d=$(dirname "$f")
      ls "$d" 2>/dev/null | grep -q 'arm64' || printf 'CHECK    32-bit arm only (GOARCH=arm != arm64): %s\n' "$f"
    done

# Unconstrained .s files: compiled for EVERY architecture.
# The filename filter must cover GOOS suffixes as well as GOARCH ones, and the
# in-file check must scan the whole leading comment block (see has_build_constraint).
find . -type d -name .git -prune -o -name '*.s' -print 2>/dev/null \
  | grep -vE "_($GOARCH_RE)[^/]*\.s$" \
  | grep -vE "_($GOOS_RE)([^/]*)?\.s$" \
  | while read -r f; do
      has_build_constraint "$f" \
        || printf 'FINDING  unconstrained .s file - compiled for every architecture: %s\n' "$f"
    done >"$TMP/unconstrained.txt"
if [ -s "$TMP/unconstrained.txt" ]; then
  cat "$TMP/unconstrained.txt"
  FINDINGS=$((FINDINGS + $(wc -l <"$TMP/unconstrained.txt" | tr -d ' ')))
else
  ok "no unconstrained .s files"
fi

# A fallback that is not an implementation.
# Narrow deliberately: `panic("not implemented")` and `panic("Unsupported int size")`
# occur all over any large vendor tree (go-cmp option stubs, json-iterator, go-winio's
# ETW field encoder) and have nothing to do with architecture. Only report a panic whose
# message names a platform or architecture, OR one inside an architecture-constrained file.
ARCH_PANIC='panic\(("|`)[^"`]*(unsupported|not implemented|no asm|no assembly)[^"`]*(platform|architecture|arch|GOARCH|amd64|arm64|386|cpu)'
ARCH_PANIC2='panic\(("|`)[^"`]*(platform|architecture|GOARCH)[^"`]*(unsupported|not supported|not implemented)'
: >"$TMP/panics.txt"
grep -rnEi --include='*.go' "$ARCH_PANIC|$ARCH_PANIC2" . 2>/dev/null >>"$TMP/panics.txt"
# Plus any generic "not implemented" panic that sits in a file the architecture gates.
while read -r f; do
  [ -n "$f" ] || continue
  grep -nEi 'panic\(("|`)[^"`]*(unsupported|not implemented)' "$f" 2>/dev/null \
    | sed "s|^|$f:|" >>"$TMP/panics.txt"
done <"$TMP/amd64files.txt"
sort -u "$TMP/panics.txt" -o "$TMP/panics.txt" 2>/dev/null
if [ -s "$TMP/panics.txt" ]; then
  finding "fallback paths that panic rather than implement (read each one):"
  sed 's/^/           /' "$TMP/panics.txt" | head -15
fi

# Test files gated on amd64 leave the portable path untested
find . -type d -name .git -prune -o -name '*_test.go' -print 2>/dev/null \
  | xargs grep -lsE '^//[[:space:]]*(go:build|\+build)[^\n]*amd64' 2>/dev/null \
  | sed 's/^/CHECK    test file gated on amd64 (portable path untested): /'

# -------------------------------------------------------- 4. native artifacts
head2 "4. Committed native artifacts"
if [ $HAVE_FILE -eq 1 ]; then
  find . -type d -name .git -prune -o -type f \
    \( -name '*.so' -o -name '*.so.*' -o -name '*.a' -o -name '*.o' -o -name '*.dylib' \) \
    -print 2>/dev/null | while read -r f; do
      printf '%s\t%s\n' "$f" "$(file -b "$f" 2>/dev/null)"
    done >"$TMP/natives.txt"
  if [ -s "$TMP/natives.txt" ]; then
    note "         $(wc -l <"$TMP/natives.txt" | tr -d ' ') native file(s) found"
    if grep -qiE 'x86-64|80386|i386' "$TMP/natives.txt"; then
      finding "x86 native artifacts committed in the tree:"
      grep -iE 'x86-64|80386|i386' "$TMP/natives.txt" | sed 's/^/           /' | head -20
    fi
    if grep -qi 'ar archive' "$TMP/natives.txt"; then
      check "static archives report no architecture; extract a member and run file on it:"
      grep -i 'ar archive' "$TMP/natives.txt" | cut -f1 | sed 's/^/           /' | head -10
    fi
    grep -iE 'aarch64' "$TMP/natives.txt" | sed 's/^/OK       aarch64 artifact: /' | head -10
    # Anything neither x86, aarch64 nor an archive is unclassified - say so rather than
    # leaving the reader to assume the file count was its own verdict.
    grep -viE 'x86-64|80386|i386|aarch64|ar archive' "$TMP/natives.txt" \
      | sed 's/^/CHECK    unclassified native file (judge it by hand): /' | head -10
  else
    ok "no committed native artifacts"
  fi
else
  check "'file' not available: native artifacts not judged by content"
fi

# Downloads naming an architecture
if grep -rqnE 'https?://[^ "'"'"']*(amd64|x86_64|x86-64)' . \
     --include='Dockerfile*' --include='Makefile' --include='*.mk' --include='*.sh' \
     --include='*.yml' --include='*.yaml' --exclude-dir=.git --exclude-dir=vendor 2>/dev/null; then
  finding "downloads hardcoding an x86 architecture in the URL:"
  grep -rnE 'https?://[^ "'"'"']*(amd64|x86_64|x86-64)' . \
    --include='Dockerfile*' --include='Makefile' --include='*.mk' --include='*.sh' \
    --include='*.yml' --include='*.yaml' --exclude-dir=.git --exclude-dir=vendor 2>/dev/null \
    | sed 's/^/           /' | head -20
else
  ok "no x86-hardcoded download URLs"
fi

# ------------------------------------------------------- 5. build config / IaC
head2 "5. Architecture selection in build and deployment configuration"

if grep -rqn -- '--platform=linux/amd64' . --exclude-dir=.git --exclude-dir=vendor 2>/dev/null; then
  finding "--platform=linux/amd64 pins a stage to x86:"
  grep -rn -- '--platform=linux/amd64' . --exclude-dir=.git --exclude-dir=vendor 2>/dev/null \
    | sed 's/^/           /' | head -10
else
  ok "no --platform=linux/amd64"
fi

if grep -rqnE 'GOARCH[[:space:]]*[:=?]{0,2}[[:space:]]*"?amd64' . \
     --include='Makefile' --include='*.mk' --include='*.sh' --include='Dockerfile*' \
     --include='*.yml' --include='*.yaml' --exclude-dir=.git --exclude-dir=vendor 2>/dev/null; then
  finding "GOARCH hardcoded to amd64:"
  grep -rnE 'GOARCH[[:space:]]*[:=?]{0,2}[[:space:]]*"?amd64' . \
    --include='Makefile' --include='*.mk' --include='*.sh' --include='Dockerfile*' \
    --include='*.yml' --include='*.yaml' --exclude-dir=.git --exclude-dir=vendor 2>/dev/null \
    | sed 's/^/           /' | head -10
else
  ok "GOARCH not hardcoded to amd64 in build scripts"
fi

if grep -rqn 'GOAMD64' . --exclude-dir=.git --exclude-dir=vendor 2>/dev/null; then
  check "GOAMD64 is set (inert on arm64, but signals x86-only tuning; GOARM64 is likely unset):"
  grep -rn 'GOAMD64' . --exclude-dir=.git --exclude-dir=vendor 2>/dev/null | sed 's/^/           /' | head -5
fi

# A --platform with no GOARCH nearby: arm64 image, amd64 binary
for df in $(find . -name 'Dockerfile*' -not -path './vendor/*' -not -path './.git/*' 2>/dev/null); do
  if grep -q -- '--platform' "$df" 2>/dev/null && ! grep -qE 'GOARCH[[:space:]]*=[[:space:]]*\$\{?TARGETARCH' "$df" 2>/dev/null; then
    finding "$df uses --platform but never sets GOARCH=\$TARGETARCH (arm64 image, amd64 binary)"
  fi
done

# GoReleaser
for gr in .goreleaser.yaml .goreleaser.yml; do
  [ -f "$gr" ] || continue
  if grep -qE '^[[:space:]]*goarch:' "$gr" 2>/dev/null; then
    if grep -A3 -E '^[[:space:]]*goarch:' "$gr" 2>/dev/null | grep -q 'arm64'; then
      ok "$gr lists arm64 in goarch"
      grep -q 'docker_manifests' "$gr" 2>/dev/null \
        || check "$gr builds multiple architectures but defines no docker_manifests (the plain tag stays single-arch)"
    else
      finding "$gr goarch does not include arm64"
    fi
  fi
done

# Deployment descriptors: wrong OR absent
if grep -rqn -iE 'provided\.al2023|AWS::Serverless::Function|aws_lambda_function|lambda\.Function' . \
     --exclude-dir=.git --exclude-dir=vendor --exclude-dir=node_modules 2>/dev/null; then
  if grep -rqn -iE 'arm64|ARM_64' . --include='*.yaml' --include='*.yml' --include='*.json' \
       --include='*.tf' --include='*.ts' --include='*.py' --exclude-dir=.git --exclude-dir=vendor 2>/dev/null; then
    ok "Lambda definitions mention arm64 (verify it is on the right resource)"
  else
    finding "Lambda definitions present with no arm64 architecture set (absent defaults to x86_64)"
  fi
fi
if grep -rqn 'runtimePlatform\|cpuArchitecture' . --exclude-dir=.git --exclude-dir=vendor 2>/dev/null; then
  grep -rn 'cpuArchitecture' . --exclude-dir=.git --exclude-dir=vendor 2>/dev/null \
    | grep -vi 'ARM64' | sed 's/^/FINDING  ECS cpuArchitecture not ARM64: /' | head -5
fi

# --------------------------------------------------------- 6. behavioral leads
head2 "6. Behavioral leads (compile cleanly; verified only by Phase 3)"

grep -rl --include='*.go' 'cpu\.X86\.' . --exclude-dir=vendor 2>/dev/null \
  | while read -r f; do
      grep -q 'cpu\.ARM64\.' "$f" || printf 'CHECK    x86-only CPU dispatch (read the final else): %s\n' "$f"
    done

if grep -rqn --include='*.go' -E 'syscall\.SYS_|unix\.SYS_' . --exclude-dir=vendor 2>/dev/null; then
  check "direct syscall constants (a missing one is a compile error; a numeric seccomp filter is silent):"
  grep -rn --include='*.go' -E 'syscall\.SYS_|unix\.SYS_' . --exclude-dir=vendor 2>/dev/null \
    | sed 's/^/           /' | head -10
fi

if grep -rqn -iE 'AUDIT_ARCH_X86_64|SCMP_ARCH_X86_64' . --exclude-dir=.git --exclude-dir=vendor 2>/dev/null; then
  finding "seccomp/BPF pinned to an x86 architecture (fails open or closed on arm64):"
  grep -rn -iE 'AUDIT_ARCH_X86_64|SCMP_ARCH_X86_64' . --exclude-dir=.git --exclude-dir=vendor 2>/dev/null \
    | sed 's/^/           /' | head -5
fi

if grep -rqn --include='*.go' -E '\b4096\b' . --exclude-dir=vendor 2>/dev/null; then
  check "hardcoded 4096 present; a finding only where it is used page-granularly (grade against the target's getconf PAGESIZE)"
fi

nrace=$(grep -rn 'go test' . --include='Makefile' --include='*.mk' --include='*.sh' \
          --include='*.yml' --include='*.yaml' --exclude-dir=.git 2>/dev/null | grep -c -- '-race')
if [ "${nrace:-0}" -eq 0 ]; then
  finding "no 'go test -race' anywhere in the build or CI configuration - the weak-memory-order risk is UNMEASURED"
else
  ok "'go test -race' appears in $nrace place(s); run it on arm64 (exit criterion 9)"
fi

# ---------------------------------------------------------------------- result
head2 "Result"
note "findings: $FINDINGS    checks: $CHECKS"
note ""
note "A CHECK is a lead, not a verdict. Resolve every one before writing a PASS."
note "Shape C blockers, cgo routes and the race result all require the full skill:"
note "  phases/phase1-static-analysis.md, phase2-resolution.md, phase3-validation.md"

if [ -n "$OUT" ]; then
  note ""
  note "(-o was given; this script writes nothing. Redirect stdout instead:"
  note "   ./go_arch_scan.sh . > $OUT/go-arch-scan.txt )"
fi

[ "$FINDINGS" -gt 0 ] && exit 1
exit 0
