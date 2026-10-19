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

# excluded_from_target FILE - true when the file's own build constraint excludes
# linux/arm64, so it is never compiled for this target and nothing in it is a finding.
#
# This is what separates a real stub from a harmless one. Measured on containerd's
# vendor tree: wazero's isa_other.go is gated `//go:build !(amd64 || arm64)` and panics
# with "unsupported architecture" - correct code, excluded on arm64, and reporting it is
# noise. grpc's raw_conn_nonlinux.go is gated `//go:build !linux` and panics likewise.
excluded_from_target() {
  awk '
    /^[[:space:]]*\/\/[[:space:]]*(go:build|\+build)/ {
      line=$0
      # !arm64 / !(... arm64 ...) / !linux / !(... linux ...) all exclude this target
      if (line ~ /![[:space:]]*arm64/)  { print "x"; exit }
      if (line ~ /![[:space:]]*linux/)  { print "x"; exit }
      if (line ~ /!\([^)]*arm64[^)]*\)/) { print "x"; exit }
      if (line ~ /!\([^)]*linux[^)]*\)/) { print "x"; exit }
      exit
    }
    /^[[:space:]]*$/      { next }
    /^[[:space:]]*\/\//   { next }
    { exit }
    NR > 200              { exit }
  ' "$1" 2>/dev/null | grep -q x
}

# has_basename DIR REGEX - true when DIR holds a file whose BASENAME matches REGEX.
# Replaces `ls "$d" | grep -q ...`, which breaks on filenames with newlines or
# leading dashes (shellcheck SC2010).
has_basename() {
  local d=$1 re=$2 f
  for f in "$d"/*; do
    [ -e "$f" ] || continue
    printf '%s\n' "${f##*/}" | grep -qE "$re" && return 0
  done
  return 1
}

# portable_sibling DIR - true when the directory holds a path that builds on arm64
# besides the amd64-suffixed ones: an arm64 file, an explicitly-named generic file, a
# file gated `!amd64`, OR an unsuffixed file carrying NO constraint at all.
#
# The last case is the one that matters in practice and the one a naive check misses.
# Measured: klauspost/compress/internal/cpuinfo ships cpuinfo_amd64.go (gated
# `amd64 && !appengine && !noasm && gc`) beside a plain cpuinfo.go with no constraint
# line. That is textbook Shape B, and without this clause it is reported as a possible
# Shape C blocker on correct, widely-deployed code.
portable_sibling() {
  local d=$1 f base
  has_basename "$d" 'arm64' && return 0
  has_basename "$d" '_(generic|purego|noasm|portable|other|fallback|compat|ref)[^.]*\.(go|s)$' && return 0
  grep -lsE '^//[[:space:]]*(go:build|\+build)[^\n]*!amd64' "$d"/*.go >/dev/null 2>&1 && return 0
  for f in "$d"/*.go; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in *_test.go) continue ;; esac
    # an unsuffixed file (no GOOS/GOARCH in its name) with no constraint builds everywhere
    printf '%s\n' "$base" | grep -qE "_($GOOS_RE|$GOARCH_RE)(_($GOARCH_RE))?\.go$" && continue
    has_build_constraint "$f" || return 0
  done
  return 1
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

    # Any other arm64-only resolution error.
    # `go` writes module download progress to STDERR, and the first invocation warms the
    # cache for the second - so without filtering, the arm64 pass always "reports errors
    # the amd64 pass did not" and the finding is pure ordering noise.
    PROGRESS='^go: (downloading|extracting|finding|upgraded|added|to add module|downloading module)'
    grep -vE "$PROGRESS" "$TMP/deps-arm64.err" 2>/dev/null | grep -v '^[[:space:]]*$' >"$TMP/e-arm64"
    grep -vE "$PROGRESS" "$TMP/deps-amd64.err" 2>/dev/null | grep -v '^[[:space:]]*$' >"$TMP/e-amd64"
    if [ -s "$TMP/e-arm64" ] && ! cmp -s "$TMP/e-arm64" "$TMP/e-amd64"; then
      check "arm64 resolution produced errors that amd64 did not; read them:"
      sed 's/^/           /' "$TMP/e-arm64" | head -10
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
  \( -name '*_amd64*.go' -o -name '*_amd64*.s' \) \
  -print 2>/dev/null | sort >"$TMP/amd64files.all"
# _386 is deliberately NOT in the glob. The migration source for Graviton is x86-64, and
# a 386/non-386 pair is complete for arm64 by construction. Measured: klauspost/compress
# internal/regmask ships regmask_386.go (`//go:build 386`) beside regmask.go
# (`//go:build !386`), and including _386 reported that correct pair as an amd64 problem.

# Test files are a coverage question, not a build shape: an _amd64_test.go with no arm64
# counterpart means that test never runs on Graviton, which is worth one line and is not
# a blocker. Measured: minio internal/s3select/simdj's ONLY amd64-suffixed file is
# reader_amd64_test.go, and treating it as a build shape accused a package that builds.
grep -E '_test\.go$' "$TMP/amd64files.all" > "$TMP/amd64tests.txt" 2>/dev/null || true
grep -vE '_test\.go$' "$TMP/amd64files.all" > "$TMP/amd64files.raw" 2>/dev/null || true
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
nt=$(wc -l <"$TMP/amd64tests.txt" | tr -d ' ')
note "         amd64-suffixed source files: $na    arm64-suffixed: $nr    (skipped $nskip non-linux-GOOS, $nt test files)"

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
    if has_basename "$d" 'arm64'; then
      printf 'OK       Shape A (ported): %s\n' "$d"
    elif portable_sibling "$d"; then
      printf 'CHECK    Shape B (builds, read the fallback body): %s\n' "$d"
      CHECKS=$((CHECKS+1))
    else
      printf 'CHECK    Shape B or C - no arm64 sibling and no portable path found: %s\n' "$d"
      CHECKS=$((CHECKS+1))
    fi
  done <"$TMP/amd64dirs.txt"
  note "         (Shape C is confirmed only by 'build constraints exclude all Go files' in section 1)"
fi

# amd64-only tests: a coverage gap, reported once rather than per file
if [ "${nt:-0}" -gt 0 ]; then
  sed 's|/[^/]*$||' "$TMP/amd64tests.txt" | sort -u >"$TMP/amd64testdirs.txt"
  ntd=0
  while read -r d; do
    [ -n "$d" ] || continue
    has_basename "$d" '_arm64.*_test\.go$' && continue
    ntd=$((ntd+1)); printf '           %s\n' "$d"
  done <"$TMP/amd64testdirs.txt" >"$TMP/testgap.txt"
  if [ -s "$TMP/testgap.txt" ]; then
    check "amd64-only test files - these tests never run on Graviton (coverage gap, not a blocker):"
    head -10 "$TMP/testgap.txt"
  fi
fi

# Files constrained to 32-bit arm with no arm64 sibling: looks ported, is not
find . -type d -name .git -prune -o -type f \( -name '*_arm.go' -o -name '*_arm.s' \) -print 2>/dev/null \
  | while read -r f; do
      irrelevant_path "$f" && continue
      d=$(dirname "$f")
      has_basename "$d" 'arm64' || printf 'CHECK    32-bit arm only (GOARCH=arm != arm64): %s\n' "$f"
    done

# Unconstrained .s files: compiled for EVERY architecture.
# The filename filter must cover GOOS suffixes as well as GOARCH ones, the in-file check
# must scan the whole leading comment block (see has_build_constraint), and a file inside
# a non-linux GOOS package is not this target's problem (golang.org/x/sys/plan9/asm.s).
find . -type d -name .git -prune -o -name '*.s' -print 2>/dev/null \
  | grep -vE "_($GOARCH_RE)[^/]*\.s$" \
  | grep -vE "_($GOOS_RE)([^/]*)?\.s$" \
  | while read -r f; do
      irrelevant_path "$f" && continue
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
# Two filters, both measured as necessary against containerd's vendor tree:
#   - the message must name an ARCHITECTURE. "platform" alone matches grpc's
#     `panic("RawConn functionality is not implemented for non-unix platforms.")`,
#     and `panic("not implemented")` / `panic("Unsupported int size")` occur all over
#     go-cmp, json-iterator and go-winio with no architecture meaning at all.
#   - the file must not be excluded from linux/arm64 by its own constraint. wazero's
#     isa_other.go is gated `!(amd64 || arm64)` and panics "unsupported architecture":
#     correct code, never compiled here.
ARCH_PANIC='panic\(("|`)[^"`]*(unsupported|not implemented|no asm|no assembly|not supported)[^"`]*(architecture|arch|GOARCH|amd64|arm64|aarch64|cpu|simd|sse|avx|neon)'
ARCH_PANIC2='panic\(("|`)[^"`]*(architecture|GOARCH|amd64|arm64|aarch64)[^"`]*(unsupported|not supported|not implemented)'
: >"$TMP/panics.raw"
grep -rlEi --include='*.go' "$ARCH_PANIC|$ARCH_PANIC2" . 2>/dev/null >>"$TMP/panics.raw"
while read -r f; do
  [ -n "$f" ] || continue
  grep -qEi 'panic\(("|`)[^"`]*(unsupported|not implemented)' "$f" 2>/dev/null \
    && printf '%s\n' "$f" >>"$TMP/panics.raw"
done <"$TMP/amd64files.txt"
sort -u "$TMP/panics.raw" -o "$TMP/panics.raw" 2>/dev/null
: >"$TMP/panics.txt"
while read -r f; do
  [ -f "$f" ] || continue
  irrelevant_path "$f" && continue
  excluded_from_target "$f" && continue
  grep -nEi "$ARCH_PANIC|$ARCH_PANIC2|panic\\((\"|\`)[^\"\`]*(unsupported|not implemented)" "$f" 2>/dev/null \
    | sed "s|^|$f:|" >>"$TMP/panics.txt"
done <"$TMP/panics.raw"
if [ -s "$TMP/panics.txt" ]; then
  finding "fallback paths that panic rather than implement (read each one):"
  sed 's/^/           /' "$TMP/panics.txt" | head -15
fi

# Test files gated on amd64 leave the portable path untested
find . -type d -name .git -prune -o -name '*_test.go' -print 2>/dev/null \
  | while read -r tf; do
      grep -lsE '^//[[:space:]]*(go:build|\+build)[^\n]*amd64' "$tf" 2>/dev/null
    done \
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

# Downloads naming an architecture.
# Aggregate: a repo's test and docs scripts commonly fetch the same amd64 tool a dozen
# times (minio: 16 hits for `mc`), and emitting one finding per line buries everything
# else. One finding, a count, and the distinct URLs.
DL_X86='https?://[^ "'"'"']*(amd64|x86_64|x86-64)'
grep -rnE "$DL_X86" . \
  --include='Dockerfile*' --include='Makefile' --include='*.mk' --include='*.sh' \
  --include='*.yml' --include='*.yaml' --exclude-dir=.git --exclude-dir=vendor 2>/dev/null \
  >"$TMP/dl.txt"
if [ -s "$TMP/dl.txt" ]; then
  ndl=$(wc -l <"$TMP/dl.txt" | tr -d ' ')
  grep -ohE "$DL_X86" "$TMP/dl.txt" 2>/dev/null | sort -u >"$TMP/dlurls.txt"
  nurl=$(wc -l <"$TMP/dlurls.txt" | tr -d ' ')
  finding "x86-hardcoded download URLs: $ndl occurrence(s) of $nurl distinct URL(s). Make each derive the arch from \$TARGETARCH or uname -m:"
  sed 's|^|           |' "$TMP/dlurls.txt" | head -12
  [ "$nurl" -gt 12 ] && note "           ... and $((nurl-12)) more (full list: grep -rnE '$DL_X86' .)"
  note "           first occurrences:"
  sed 's|^|             |' "$TMP/dl.txt" | head -5
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

# A --platform with no GOARCH nearby: arm64 image, amd64 binary.
#
# BUT a cross-compilation wrapper sets GOARCH for you, and accusing a repo that uses one
# is a false positive on idiomatic code. Measured on containerd's
# .github/workflows/release/Dockerfile: it uses tonistiigi/xx, where `xx-go --wrap`
# derives GOARCH from $TARGETPLATFORM and `xx-verify` then checks the output binary's
# architecture - so there is no literal GOARCH=$TARGETARCH anywhere and the Dockerfile
# is correct. Recognize the wrappers before claiming the defect.
XX_WRAPPER='xx-go|xx-info|xx-verify|xx-apt|xx-cc|xx-clang|--wrap|GOARCH=\$\{?TARGETARCH|GOARCH="?\$\{?TARGETARCH|goreleaser|ko build|CC=\$\(xx-info\)'
for df in $(find . -name 'Dockerfile*' -not -path './vendor/*' -not -path './.git/*' 2>/dev/null); do
  grep -q -- '--platform' "$df" 2>/dev/null || continue
  if grep -qE "$XX_WRAPPER" "$df" 2>/dev/null; then
    ok "$df uses --platform with a cross-compile wrapper (xx-go / TARGETARCH); verify the built binary's arch in Phase 3.3"
  else
    finding "$df uses --platform but never sets GOARCH=\$TARGETARCH and uses no cross-compile wrapper (arm64 image, amd64 binary)"
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
