#!/usr/bin/env bash
# go_arch_scan.sh - read-only arm64 readiness scan for a Go project.
#
# Covers the deterministic parts of Phase 1: cgo inventory, build constraints and
# assembly, committed native artifacts, and architecture selection in build scripts
# and deployment descriptors.
#
# READ-ONLY. It never writes inside the scanned tree (the only file it writes is the
# one named by -o) and never runs the project's own build. With the Go toolchain
# available it uses `go list` as the fact base; without it, it falls back to a
# grep-only mode in which every verdict is CHECK.
#
# Directories are judged by the go command's own rules: testdata/, vendor/ (for
# package enumeration), and directories starting with `_` or `.` are not packages,
# and every nested go.mod is a separate module that is resolved on its own.
#
# Requires bash 3.2+ and POSIX tools (find, grep, sed, awk, xargs). No python.

set -u

usage() {
  cat <<'EOF'
usage: go_arch_scan.sh [flags] [PROJECT_DIR]

Read-only arm64 readiness scan of a Go project (default PROJECT_DIR: .).

flags:
  -tags LIST   build tags, comma-separated, exactly as passed to `go build -tags`.
               Use the DEPLOYMENT's tags: a Shape C blocker behind a tag is
               invisible to a scan without it.
  -o FILE      also write the report to FILE (if FILE is a directory, to
               FILE/go-arch-scan.txt, or FILE/go-arch-scan.json with -json)
  -json        print the report as one JSON document instead of text
  -strict      advisories also fail the scan (exit 1)
  -h, -help    this help

Flags take one or two dashes, and -flag=value or -flag value.

Output levels:
  FINDING   arm64 migration work is required here
  ADVISORY  not a blocker: a gap in how the project is tested or checked
  CHECK     a lead the scanner cannot decide; resolve it before writing a PASS
  OK        checked and fine (recorded so nobody "fixes" it later)

Exit status:
  0  no findings (advisories and checks do not fail the scan unless -strict)
  1  findings present (or advisories present with -strict)
  2  usage error, not a Go project, or cannot run
EOF
}

die_usage() { printf 'go_arch_scan: %s\n' "$1" >&2; usage >&2; exit 2; }

PROJECT=""
OUT=""
TAGS=""
JSON=0
STRICT=0
set_project() {
  [ -z "$PROJECT" ] || die_usage "more than one project directory: '$PROJECT' and '$1'"
  PROJECT=$1
}
while [ $# -gt 0 ]; do
  case "$1" in
    -tags|--tags)     [ $# -ge 2 ] || die_usage "$1 needs a value"; TAGS=$2; shift 2 ;;
    -tags=*|--tags=*) TAGS=${1#*=}; shift ;;
    -o|--out)         [ $# -ge 2 ] || die_usage "$1 needs a value"; OUT=$2; shift 2 ;;
    -o=*|--out=*)     OUT=${1#*=}; shift ;;
    -json|--json)     JSON=1; shift ;;
    -strict|--strict) STRICT=1; shift ;;
    -h|-help|--help)  usage; exit 0 ;;
    --)               shift; [ $# -le 1 ] || die_usage "more than one project directory after --"
                      [ $# -eq 1 ] && set_project "$1"; break ;;
    -*)               die_usage "unknown flag: $1" ;;
    *)                set_project "$1"; shift ;;
  esac
done
PROJECT=${PROJECT:-.}
# `go build -tags` accepts commas; the legacy space-separated form is normalized.
TAGS=$(printf '%s' "$TAGS" | tr -s ' ' ',' | sed 's/^,//; s/,$//')

# -o is resolved against the directory the user ran us from, before the cd below.
if [ -n "$OUT" ]; then
  case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac
  if [ -d "$OUT" ]; then
    if [ $JSON -eq 1 ]; then OUT="$OUT/go-arch-scan.json"; else OUT="$OUT/go-arch-scan.txt"; fi
  fi
  [ -d "$(dirname "$OUT")" ] || { echo "go_arch_scan: -o: directory does not exist: $(dirname "$OUT")" >&2; exit 2; }
fi

[ -d "$PROJECT" ] || { echo "go_arch_scan: not a directory: $PROJECT" >&2; exit 2; }
cd "$PROJECT" || exit 2
[ -f go.mod ] || [ -f go.work ] || {
  echo "go_arch_scan: no go.mod or go.work in $(pwd): not a Go project" >&2; exit 2; }
ROOT=$(pwd)

# Every verdict is a line with one of four prefixes. The totals and the exit status are
# COUNTED FROM THE REPORT at the end, never kept in variables: half the checks below run
# inside pipelines and while-loops (subshells), and an earlier version's counters missed
# every finding printed there - the ECS cpuArchitecture finding never affected the exit
# status at all.
note()     { printf '%s\n' "$*"; }
head2()    { printf '\n== %s ==\n' "$*"; }
finding()  { printf 'FINDING  %s\n' "$*"; }
advisory() { printf 'ADVISORY %s\n' "$*"; }
check()    { printf 'CHECK    %s\n' "$*"; }
ok()       { printf 'OK       %s\n' "$*"; }
count_lines() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }
# Absolute paths from `go list` are printed relative to the scanned root.
rel() { sed -e "s|$ROOT/|./|g" -e "s|$ROOT\$|.|"; }

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

SC_MSG='build constraints exclude all Go files'

# ------------------------------------------------- the go command's directory rules
#
# The go command does not treat every directory holding a .go file as a package:
#   - `testdata` directories are ignored (they hold fixtures, often deliberately broken)
#   - directories whose name starts with `_` or `.` are ignored
#   - `vendor/` holds dependencies, which are reached through the import graph
#   - a directory with its own go.mod is a DIFFERENT module, not a package of this one
# Measured: an earlier version enumerated with `find . -name '*.go'`, reported an
# amd64-only file under internal/fixtures/testdata/ and one under _scratch/ as two Shape C
# FINDINGs (the go command never builds either), and silently missed a real, imported
# Shape C package in a nested module because `go list ./svc/...` from the parent module
# does not see a nested module's packages at all.

# gofind PREDICATES... - find(1) from ., pruning what the go command never builds.
# vendor/ is NOT pruned: the build-constraint scan reads it deliberately.
gofind() {
  find . \( -type d \( -name testdata -o -name '_*' -o -name '.?*' \) -prune \) -o "$@" 2>/dev/null
}

# list_modules - every module root in the tree, as the go command would recognize them.
list_modules() {
  find . \( -type d \( -name vendor -o -name testdata -o -name '_*' -o -name '.?*' \) -prune \) \
    -o -type f -name go.mod -print 2>/dev/null | sed 's|/go.mod$||' | sort
}

# list_pkg_dirs - run inside a module root: every directory that is a package of THIS
# module (nested modules, vendor, testdata, _ and . directories excluded).
list_pkg_dirs() {
  find . \( -type d \( -name vendor -o -name testdata -o -name '_*' -o -name '.?*' \) -prune \) \
    -o \( -type d ! -name . -exec test -f '{}/go.mod' \; -prune \) \
    -o \( -type f -name '*.go' ! -name '_*' ! -name '.*' -print \) 2>/dev/null \
    | sed 's|/[^/]*$||' | sort -u
}

# go_ignored_path PATH - true when the go command never builds PATH.
go_ignored_path() {
  printf '%s\n' "$1" | grep -qE '/(testdata|_[^/]*|\.[^/]+)/'
}

# explain_resolution_error FILE - name the cause of a failed resolution, rather than
# leaving the reader to guess. These are the ones that actually happen; most of them are
# the environment rather than the code.
explain_resolution_error() {
  if grep -qE 'GOCACHE is not defined|neither \$XDG_CACHE_HOME nor \$HOME|module cache not found|neither GOMODCACHE nor GOPATH' "$1" 2>/dev/null; then
    note "           cause: no HOME/GOCACHE/GOMODCACHE in this environment (common under"
    note "                  CI runners, sudo, SSM Run Command and container entrypoints)."
    note "           fix:   export HOME=/root GOCACHE=\$HOME/.cache/go-build GOMODCACHE=\$HOME/go/pkg/mod"
  elif grep -qE 'toolchain not available|requires go >=|GOTOOLCHAIN' "$1" 2>/dev/null; then
    note "           cause: go.mod (or go.work) requires a newer Go than this host has, and it"
    note "                  could not be downloaded."
    note "           fix:   install the toolchain go.mod names, or allow GOTOOLCHAIN=auto with proxy access"
  elif grep -qE 'missing go.sum entry|no required module provides|module .* found .* but does not contain|cannot find module providing' "$1" 2>/dev/null; then
    note "           cause: dependencies not downloaded."
    note "           fix:   go mod download   (or use the committed vendor/ with -mod=vendor)"
  elif grep -qE 'dial tcp|i/o timeout|proxy.golang.org|certificate|410 Gone' "$1" 2>/dev/null; then
    note "           cause: the module proxy is unreachable."
    note "           fix:   provide proxy access, or scan a checkout that has vendor/"
  elif grep -qE 'unrecognized import path|terminal prompts disabled|authentication required' "$1" 2>/dev/null; then
    note "           cause: a private module cannot be resolved."
    note "           fix:   set GOPRIVATE and the host's credentials, or scan with vendor/"
  fi
}

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

# One row per package, tab-separated, from `go list -e -deps -f`. Fields:
#   1 ImportPath  2 std|-  3 len(CgoFiles)  4 CgoLDFLAGS  5 CgoCFLAGS  6 CgoPkgConfig
#   7 context.CgoEnabled  8 Error (quoted)  9 Dir  10 Imports
# `-e` puts each package's error in its own row instead of aborting the listing, so a
# Shape C package, a missing module and a healthy package are told apart per package
# rather than by grepping stderr. ImportStack is not used: its type changed in go1.27
# (`wrong type for value; expected []string; got load.ImportStack`); importers are
# derived from field 10 instead.
DEPS_TPL='{{.ImportPath}}{{"\t"}}{{if .Standard}}std{{else}}-{{end}}{{"\t"}}{{len .CgoFiles}}{{"\t"}}{{join .CgoLDFLAGS " "}}{{"\t"}}{{join .CgoCFLAGS " "}}{{"\t"}}{{join .CgoPkgConfig " "}}{{"\t"}}{{context.CgoEnabled}}{{"\t"}}{{with .Error}}{{printf "%q" .Err}}{{end}}{{"\t"}}{{.Dir}}{{"\t"}}{{join .Imports " "}}'
DIR_TPL='{{.Dir}}{{"\t"}}{{with .Error}}{{printf "%q" .Err}}{{end}}'

TMP="${TMPDIR:-/tmp}/go_arch_scan.$$"
mkdir -p "$TMP" || exit 2
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# resolve_module DIR INDEX - capture the dependency set of one module for both
# architectures. A module that is not listed in the go.work above it is retried with
# GOWORK=off, which is how the go command itself would build it standalone.
resolve_module() {
  _m=$1; _i=$2; _env=""
  for _a in arm64 amd64; do
    ( cd "$_m" && CGO_ENABLED=1 GOOS=linux GOARCH=$_a \
        go list -e -deps -tags="$TAGS" -f "$DEPS_TPL" ./... ) \
      >"$TMP/d.$_i.$_a" 2>"$TMP/d.$_i.$_a.err"
  done
  # A module counts as resolved only if at least one package came back WITHOUT an error.
  # Under -e a pattern-level failure is not an empty listing: it is a single fake row
  # for "./..." carrying the error (measured: "pattern ./...: directory prefix . does not
  # contain modules listed in go.work"), so "stdout is non-empty" would read it as success.
  resolved_ok() { awk -F'\t' '$8==""{f=1} END{exit !f}' "$1"; }
  if ! resolved_ok "$TMP/d.$_i.arm64" \
     && cat "$TMP/d.$_i.arm64" "$TMP/d.$_i.arm64.err" 2>/dev/null | grep -q 'go\.work'; then
    _env="GOWORK=off"
    for _a in arm64 amd64; do
      ( cd "$_m" && env GOWORK=off CGO_ENABLED=1 GOOS=linux GOARCH=$_a \
          go list -e -deps -tags="$TAGS" -f "$DEPS_TPL" ./... ) \
        >"$TMP/d.$_i.$_a" 2>"$TMP/d.$_i.$_a.err"
    done
  fi
  if resolved_ok "$TMP/d.$_i.arm64"; then
    printf '%s\t%s\t%s\n' "$_i" "$_m" "$_env" >>"$TMP/ok.mods"
    [ -n "$_env" ] && note "         module $_m is not listed in go.work: resolved standalone (GOWORK=off)"
    cat "$TMP/d.$_i.arm64" >>"$TMP/pkgs.arm64"
    cat "$TMP/d.$_i.amd64" >>"$TMP/pkgs.amd64"
  elif grep -q 'matched no packages' "$TMP/d.$_i.arm64.err" 2>/dev/null; then
    note "         module $_m has no packages"
  else
    printf '%s\n' "$_m" >>"$TMP/failed.mods"
    { printf '[module %s]\n' "$_m"; cat "$TMP/d.$_i.arm64.err"
      awk -F'\t' '$8!=""{print $1": "$8}' "$TMP/d.$_i.arm64"; } >>"$TMP/resolve.err"
  fi
}

# sweep_module INDEX DIR ENV CGO GOARCH OUTFILE - list every package directory of one
# module explicitly, in ONE go list call (batched by xargs), not one call per directory.
# Measured on golang.org/x/text (67 package directories): 2.6 s for the per-directory
# loop of three passes, 0.22 s batched, with identical results.
sweep_module() {
  [ -s "$TMP/dirs.$1" ] || return 0
  # shellcheck disable=SC2086
  ( cd "$2" && tr '\n' '\0' <"$TMP/dirs.$1" \
      | xargs -0 env $3 CGO_ENABLED="$4" GOOS=linux GOARCH="$5" \
          go list -e -tags="$TAGS" -f "$DIR_TPL" ) >>"$TMP/$6" 2>>"$TMP/sweep.err"
}

scan_body() {
note "go_arch_scan - $ROOT"
note "toolchain: $([ $HAVE_GO -eq 1 ] && go version 2>/dev/null || echo 'go NOT FOUND - grep-only mode, all verdicts CHECK')"
note "tags:      ${TAGS:-(none)}"

# ---------------------------------------------------------------- 1. resolution
head2 "1. Resolution for linux/arm64"
nmod=0
if [ $HAVE_GO -eq 1 ]; then
  list_modules >"$TMP/modules"
  nmod=$(count_lines "$TMP/modules")
  if [ "$nmod" -eq 0 ]; then
    check "no go.mod under $ROOT (does go.work point outside the tree?) - nothing to resolve"
    HAVE_GO=0
  fi
fi
if [ $HAVE_GO -eq 1 ]; then
  [ "$nmod" -gt 1 ] && note "         $nmod modules: $(tr '\n' ' ' <"$TMP/modules")"
  : >"$TMP/pkgs.arm64"; : >"$TMP/pkgs.amd64"; : >"$TMP/ok.mods"
  : >"$TMP/failed.mods"; : >"$TMP/resolve.err"
  # CGO_ENABLED=1 is deliberate: go list populates CgoFiles only when cgo is enabled.
  # With it off, cgo files move to IgnoredGoFiles and a cgo project looks pure Go.
  i=0
  while read -r m; do
    i=$((i+1))
    resolve_module "$m" "$i"
  done <"$TMP/modules"

  # STEP 1 - did the capture actually succeed? Nothing below may claim a verdict until
  # this is answered. A failed capture produces no rows, and reading "no findings" out
  # of that is how an empty result becomes a false all-clear.
  awk -F'\t' '$8==""{print $1}' "$TMP/pkgs.arm64" | sort -u >"$TMP/okpkgs.arm64"
  npkg=$(count_lines "$TMP/okpkgs.arm64")
  nfail=$(count_lines "$TMP/failed.mods")
  { cat "$TMP/resolve.err"; awk -F'\t' '$8!=""{print $1": "$8}' "$TMP/pkgs.arm64"; } >"$TMP/all.err"

  if [ "$npkg" -eq 0 ]; then
    check "go list resolved 0 packages - RESOLUTION FAILED. No Shape C verdict is possible;"
    note  "           every verdict below is CHECK, including the ones that print OK."
    explain_resolution_error "$TMP/all.err"
    note "           raw errors (first 6 lines):"
    sed 's/^/             /' "$TMP/all.err" | head -6
    HAVE_GO=0
  else
    ok "resolved $npkg packages for linux/arm64 in $((nmod-nfail)) of $nmod module(s)"
    if [ "$nfail" -gt 0 ]; then
      check "$nfail module(s) did not resolve - nothing in them is verified:"
      sed 's/^/           /' "$TMP/failed.mods"
      explain_resolution_error "$TMP/resolve.err"
      sed 's/^/             /' "$TMP/resolve.err" | head -6
    fi

    # STEP 2 - Shape C reachable through an import: blocks the build today.
    for a in arm64 amd64; do
      awk -F'\t' -v sc="$SC_MSG" 'index($8, sc){print $1 "\t" $9}' "$TMP/pkgs.$a" \
        | sort -u >"$TMP/sc.$a"
    done
    # FILENAME, not NR==FNR: when the first file is EMPTY - the normal case, amd64 has no
    # Shape C - NR==FNR stays true through the second file and every row is swallowed.
    # Measured: that silently dropped the one reachable Shape C in a nested module.
    awk -F'\t' 'FILENAME==ARGV[1]{x[$1]=1; next} !($1 in x)' "$TMP/sc.amd64" "$TMP/sc.arm64" >"$TMP/sc.only"
    awk -F'\t' 'FILENAME==ARGV[1]{x[$1]=1; next}  ($1 in x)' "$TMP/sc.amd64" "$TMP/sc.arm64" >"$TMP/sc.both"
    if [ -s "$TMP/sc.only" ]; then
      while read -r p d; do
        imp=$(awk -F'\t' -v p="$p" '{n=split($10, a, " "); for (k=1; k<=n; k++) if (a[k]==p) {print $1; break}}' \
                "$TMP/pkgs.arm64" | sort -u | head -3 | tr '\n' ' ')
        finding "Shape C (reachable, blocks the build): $p ($(printf '%s' "$d" | rel)) imported by: ${imp:-?}"
      done <"$TMP/sc.only"
    else
      ok "no reachable Shape C package (go list -deps for arm64)"
    fi
    if [ -s "$TMP/sc.both" ]; then
      check "$(count_lines "$TMP/sc.both") imported package(s) excluded on BOTH architectures - not an arm64 problem (wrong -tags?):"
      cut -f1 "$TMP/sc.both" | sed 's/^/           /' | head -8
    fi

    # Any other per-package resolution error, compared between architectures. Errors on
    # both sides were silently ignored before: a package that cannot be resolved at all
    # is a package about which this scan proves nothing, and that must be said.
    for a in arm64 amd64; do
      awk -F'\t' -v sc="$SC_MSG" '$8!="" && !index($8, sc){print $1 "\t" $8}' "$TMP/pkgs.$a" \
        | sort -u >"$TMP/err.$a"
    done
    comm -23 "$TMP/err.arm64" "$TMP/err.amd64" >"$TMP/err.only"
    comm -12 "$TMP/err.arm64" "$TMP/err.amd64" >"$TMP/err.both"
    if [ -s "$TMP/err.only" ]; then
      check "arm64 resolution produced errors that amd64 did not; read them:"
      sed 's/^/           /' "$TMP/err.only" | rel | head -10
    fi
    if [ -s "$TMP/err.both" ]; then
      check "$(count_lines "$TMP/err.both") package(s) failed to resolve on BOTH architectures - nothing about them is verified:"
      sed 's/^/           /' "$TMP/err.both" | rel | head -6
      explain_resolution_error "$TMP/err.both"
    fi

    # STEP 3 - every package directory named explicitly. Measured: ./... silently skips
    # a package nothing imports, in go list, go build AND go vet - so step 2 alone misses
    # latent blockers. Directories follow the go command's rules (see list_pkg_dirs).
    : >"$TMP/sw.arm64"; : >"$TMP/sw.amd64"; : >"$TMP/sw.nocgo"; : >"$TMP/sweep.err"
    ndirs=0
    while IFS="$(printf '\t')" read -r i m e; do
      ( cd "$m" && list_pkg_dirs ) >"$TMP/dirs.$i"
      ndirs=$((ndirs + $(count_lines "$TMP/dirs.$i")))
      sweep_module "$i" "$m" "$e" 1 arm64 sw.arm64
      sweep_module "$i" "$m" "$e" 1 amd64 sw.amd64
      # The deployment's own CGO_ENABLED, if it is 0, can turn a pure-cgo package into
      # something that looks exactly like a Shape C blocker - see below.
      sweep_module "$i" "$m" "$e" 0 arm64 sw.nocgo
    done <"$TMP/ok.mods"
    for f in arm64 amd64 nocgo; do
      awk -F'\t' -v sc="$SC_MSG" 'index($2, sc){print $1}' "$TMP/sw.$f" | sort -u >"$TMP/swd.$f"
    done
    cut -f2 "$TMP/sc.arm64" | sort -u >"$TMP/scd.reach"
    # Reachable ones are already reported in STEP 2; reporting them again here as
    # "latent until imported" would be both a duplicate and wrong.
    comm -23 "$TMP/swd.arm64" "$TMP/swd.amd64" \
      | grep -vE "/($NON_LINUX_GOOS_RE)(/|$)" \
      | comm -23 - "$TMP/scd.reach" >"$TMP/sweep.only"
    if [ -s "$TMP/sweep.only" ]; then
      rel <"$TMP/sweep.only" | sed 's|^|FINDING  Shape C (arm64-only exclusion; latent until imported): |'
    else
      ok "per-directory sweep: no arm64-only package exclusions ($ndirs package directories)"
    fi

    # A package whose only file carries `import "C"` resolves as CgoFiles=[main.go] with
    # CGO_ENABLED=1, and with CGO_ENABLED=0 emits
    #   package X: build constraints exclude all Go files in <dir>
    # - verbatim the Shape C message (measured on go1.27.2). The fix is Phase 2.1 (cgo),
    # not Phase 2.2 (constraints), so the two must be told apart before a verdict is
    # written. Per DIRECTORY, not via ./...: a package nothing imports is skipped by ./...
    # on both passes, so the difference is always empty and the check never fires.
    sort -u "$TMP/swd.arm64" "$TMP/scd.reach" >"$TMP/cgo.dirs"
    comm -23 "$TMP/swd.nocgo" "$TMP/cgo.dirs" >"$TMP/cgoonly.dirs"
    nco=$(count_lines "$TMP/cgoonly.dirs")
    if [ "$nco" -gt 0 ]; then
      check "$nco package(s) resolve ONLY with cgo enabled - they are pure-cgo packages, NOT Shape C:"
      rel <"$TMP/cgoonly.dirs" | sed 's|^|           |' | head -8
      note "           With CGO_ENABLED=0 each emits 'build constraints exclude all Go files',"
      note "           which reads as a Shape C blocker and would route the fix to Phase 2.2."
      note "           The fix is Phase 2.1 (cgo). If the deployment sets CGO_ENABLED=0, the"
      note "           build is already broken on every architecture, not just arm64."
    fi

    # The resolved package SET, compared between architectures.
    #
    # A raw count difference is normal and must not be read as a finding. Measured on
    # RadiumGu/one-observability-demo payforadoption-go: amd64 resolves 576 packages and
    # arm64 575, and the single difference is `vendor/golang.org/x/sys/cpu` - the
    # standard library's OWN vendored copy, which the amd64 crypto packages pull in for
    # CPU feature detection and the arm64 ones reach differently. Nothing is wrong.
    #
    # What is worth reporting is a NON-STANDARD package present on one architecture and
    # not the other, because that is project or dependency code disappearing.
    for a in arm64 amd64; do
      awk -F'\t' '$2=="-" && $8=="" {print $1}' "$TMP/pkgs.$a" | sort -u >"$TMP/set.$a"
    done
    # A reachable Shape C package is missing from the arm64 set BECAUSE of the exclusion
    # already reported in STEP 2; listing it here again would be the same finding twice.
    { cut -f1 "$TMP/sc.only"; cut -f1 "$TMP/err.only"; } | sort -u >"$TMP/set.explained"
    comm -13 "$TMP/set.arm64" "$TMP/set.amd64" | comm -23 - "$TMP/set.explained" >"$TMP/set.amd64only"
    comm -23 "$TMP/set.arm64" "$TMP/set.amd64" >"$TMP/set.arm64only"
    nao=$(count_lines "$TMP/set.amd64only")
    nro=$(count_lines "$TMP/set.arm64only")
    note "         non-stdlib packages: arm64=$(count_lines "$TMP/set.arm64")  amd64=$(count_lines "$TMP/set.amd64")  (a raw count difference in the STDLIB is normal)"
    if [ "$nao" -gt 0 ]; then
      check "$nao non-stdlib package(s) resolve on amd64 but NOT on arm64 - project or dependency code is disappearing:"
      sed 's|^|           |' "$TMP/set.amd64only" | head -10
    else
      ok "the non-stdlib package set is identical on both architectures"
    fi
    if [ "$nro" -gt 0 ]; then
      note "         $nro non-stdlib package(s) resolve on arm64 only (usually an arm64-specific implementation package, which is fine):"
      sed 's|^|           |' "$TMP/set.arm64only" | head -5
    fi
  fi
else
  check "no Go toolchain: resolution and Shape C detection not verified"
fi

# ---------------------------------------------------------------------- 2. cgo
head2 "2. cgo"
if [ $HAVE_GO -eq 1 ]; then
  # From the same capture. The standard library is filtered: with CGO_ENABLED=1,
  # runtime/cgo, net and os/user report CgoFiles in every project and are never the finding.
  awk -F'\t' '$2=="-" && $3>0 && $8=="" {
      printf "%s\tfiles=%s\tLDFLAGS=[%s]\tCFLAGS=[%s]\tpkgconfig=[%s]\n", $1, $3, $4, $5, $6 }' \
    "$TMP/pkgs.arm64" | sort -u >"$TMP/cgo.txt"
  ncgo=$(count_lines "$TMP/cgo.txt")
  if [ "$ncgo" -eq 0 ]; then
    # Guard the zero with the build context itself: an empty CgoFiles from a capture that
    # ran with cgo disabled means nothing.
    if awk -F'\t' '$7=="false"{f=1} END{exit !f}' "$TMP/pkgs.arm64"; then
      check "the capture ran with cgo DISABLED, so an empty cgo inventory proves nothing. Re-capture with CGO_ENABLED=1."
    else
      ok "no package in the resolved set uses cgo (pure Go: cross-compiles without a C toolchain)"
    fi
  else
    check "$ncgo package(s) use cgo - resolve each C library's route per cgo-and-native-dependencies.md"
    sed 's/^/           /' "$TMP/cgo.txt"
  fi
else
  if grep -rq --include='*.go' --exclude-dir=testdata 'import "C"' . 2>/dev/null; then
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
if grep -rhnE --include='*.go' --exclude-dir=testdata "$CGO_DIRECTIVE" . 2>/dev/null | grep -qE "$X86_FLAG"; then
  finding "x86-only flags in #cgo directives (make them per-architecture):"
  grep -rnE --include='*.go' --exclude-dir=testdata "$CGO_DIRECTIVE" . 2>/dev/null \
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

gofind -type f \( -name '*_amd64*.go' -o -name '*_amd64*.s' \) -print | sort >"$TMP/amd64files.all"
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
nskip=$(( $(count_lines "$TMP/amd64files.raw") - $(count_lines "$TMP/amd64files.txt") ))

gofind -type f \( -name '*_arm64*.go' -o -name '*_arm64*.s' \) -print | sort >"$TMP/arm64files.txt"

na=$(count_lines "$TMP/amd64files.txt")
nr=$(count_lines "$TMP/arm64files.txt")
nt=$(count_lines "$TMP/amd64tests.txt")
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
      ok "arch-specific package dir (peer lives beside it, not inside): $d"
      continue
    }
    printf '%s\n' "$d" >>"$TMP/amd64dirs.txt"
  done <"$TMP/amd64dirs.raw"

  while read -r d; do
    [ -n "$d" ] || continue
    if has_basename "$d" 'arm64'; then
      ok "Shape A (ported): $d"
    elif portable_sibling "$d"; then
      check "Shape B (builds, read the fallback body): $d"
    else
      check "Shape B or C - no arm64 sibling and no portable path found: $d"
    fi
  done <"$TMP/amd64dirs.txt"
  note "         (Shape C is confirmed only by 'build constraints exclude all Go files' in section 1)"
fi

# amd64-only tests: a coverage gap, reported once rather than per file
if [ "${nt:-0}" -gt 0 ]; then
  sed 's|/[^/]*$||' "$TMP/amd64tests.txt" | sort -u >"$TMP/amd64testdirs.txt"
  while read -r d; do
    [ -n "$d" ] || continue
    has_basename "$d" '_arm64.*_test\.go$' && continue
    printf '           %s\n' "$d"
  done <"$TMP/amd64testdirs.txt" >"$TMP/testgap.txt"
  if [ -s "$TMP/testgap.txt" ]; then
    check "amd64-only test files - these tests never run on Graviton (coverage gap, not a blocker):"
    head -10 "$TMP/testgap.txt"
  fi
fi

# Files constrained to 32-bit arm with no arm64 sibling: looks ported, is not
gofind -type f \( -name '*_arm.go' -o -name '*_arm.s' \) -print \
  | while read -r f; do
      irrelevant_path "$f" && continue
      d=$(dirname "$f")
      has_basename "$d" 'arm64' || check "32-bit arm only (GOARCH=arm != arm64): $f"
    done

# Unconstrained .s files: compiled for EVERY architecture.
# The filename filter must cover GOOS suffixes as well as GOARCH ones, the in-file check
# must scan the whole leading comment block (see has_build_constraint), and a file inside
# a non-linux GOOS package is not this target's problem (golang.org/x/sys/plan9/asm.s).
gofind -type f -name '*.s' -print \
  | grep -vE "_($GOARCH_RE)[^/]*\.s$" \
  | grep -vE "_($GOOS_RE)([^/]*)?\.s$" \
  | while read -r f; do
      irrelevant_path "$f" && continue
      has_build_constraint "$f" \
        || finding "unconstrained .s file - compiled for every architecture: $f"
    done >"$TMP/unconstrained.txt"
if [ -s "$TMP/unconstrained.txt" ]; then
  cat "$TMP/unconstrained.txt"
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
grep -rlEi --include='*.go' --exclude-dir=.git "$ARCH_PANIC|$ARCH_PANIC2" . 2>/dev/null >>"$TMP/panics.raw"
while read -r f; do
  [ -n "$f" ] || continue
  grep -qEi 'panic\(("|`)[^"`]*(unsupported|not implemented)' "$f" 2>/dev/null \
    && printf '%s\n' "$f" >>"$TMP/panics.raw"
done <"$TMP/amd64files.txt"
sort -u "$TMP/panics.raw" -o "$TMP/panics.raw" 2>/dev/null
: >"$TMP/panics.txt"
while read -r f; do
  [ -f "$f" ] || continue
  go_ignored_path "$f" && continue
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
gofind -type f -name '*_test.go' -print \
  | while read -r tf; do
      grep -lsE '^//[[:space:]]*(go:build|\+build)[^\n]*amd64' "$tf" 2>/dev/null
    done \
  | sed 's/^/CHECK    test file gated on amd64 (portable path untested): /'

# Build tags the tree uses that this scan did not evaluate.
# A constraint is evaluated against ONE tag set. Measured: internal/fast held
# fast_amd64.go gated `prod && amd64` beside fast_generic.go gated `!prod`. Without
# -tags prod both architectures pick the generic file and nothing is reported; with it
# the package is excluded on arm64 only - a real Shape C, invisible to an untagged scan.
# Test files are left out: test-only tags (integration, e2e) never reach the release build.
grep -rhE --include='*.go' --exclude='*_test.go' --exclude-dir=vendor --exclude-dir=testdata \
     --exclude-dir='_*' --exclude-dir=.git '^//go:build[[:space:]]' . 2>/dev/null \
  | sed 's|^//go:build||' | tr -c 'A-Za-z0-9_.\n' ' ' | tr -s ' ' '\n' \
  | grep -E '^[A-Za-z_][A-Za-z0-9_.]*$' \
  | grep -vxE "($GOOS_RE|$GOARCH_RE|cgo|gc|gccgo|unix|ignore|tools|race|msan|asan|go1\.[0-9]+|goexperiment\..*)" \
  | sort -u >"$TMP/tags.used"
printf '%s\n' "$TAGS" | tr ',' '\n' | grep -v '^$' | sort -u >"$TMP/tags.given"
comm -23 "$TMP/tags.used" "$TMP/tags.given" >"$TMP/tags.unevaluated"
if [ -s "$TMP/tags.unevaluated" ]; then
  check "build tags used in this tree were NOT evaluated (scanned with -tags='$TAGS'): $(head -15 "$TMP/tags.unevaluated" | tr '\n' ' ')"
  note "           A Shape C blocker behind a tag is invisible without it. Re-run with the"
  note "           DEPLOYMENT's tags (skill-config.md build_tags), e.g. -tags $(head -1 "$TMP/tags.unevaluated")"
fi

# -------------------------------------------------------- 4. native artifacts
head2 "4. Committed native artifacts"
if [ $HAVE_FILE -eq 1 ]; then
  find . -type d -name .git -prune -o -type f \
    \( -name '*.so' -o -name '*.so.*' -o -name '*.a' -o -name '*.o' -o -name '*.dylib' \) \
    -print 2>/dev/null | while read -r f; do
      printf '%s\t%s\n' "$f" "$(file -b "$f" 2>/dev/null)"
    done >"$TMP/natives.txt"
  if [ -s "$TMP/natives.txt" ]; then
    note "         $(count_lines "$TMP/natives.txt") native file(s) found"
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
  ndl=$(count_lines "$TMP/dl.txt")
  grep -ohE "$DL_X86" "$TMP/dl.txt" 2>/dev/null | sort -u >"$TMP/dlurls.txt"
  nurl=$(count_lines "$TMP/dlurls.txt")
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

# NOTE on `--`: it ends option processing, so `grep -rn -- PATTERN . --include=...`
# silently treats --include as a PATH and the filter never applies. The pattern here
# starts with a dash, so it is passed with -e instead and the filters stay effective.
# Measured: with `--` the exclusion was ignored and a Dockerfile hit was reported twice,
# once correctly as a build-file defect and once wrongly as a documentation hit.
PLAT_AMD64='--platform=linux/amd64'
if grep -rn --exclude-dir=.git --exclude-dir=vendor \
     --exclude='*.md' --exclude='*.rst' --exclude='*.txt' \
     -e "$PLAT_AMD64" . >"$TMP/plat.txt" 2>/dev/null && [ -s "$TMP/plat.txt" ]; then
  finding "--platform=linux/amd64 pins a stage to x86:"
  sed 's/^/           /' "$TMP/plat.txt" | head -10
else
  ok "no --platform=linux/amd64 in build files"
fi
# Documentation is a separate, lower-severity class: a README telling a human to build
# amd64 is worth knowing and is not a build-stage defect. Measured: payforadoption-go's
# benchmark/README.md carries `docker buildx build ... --platform=linux/amd64` for a
# different image entirely, and reporting it as a pinned stage was wrong.
if grep -rn --include='*.md' --include='*.rst' --include='*.txt' \
     --exclude-dir=.git --exclude-dir=vendor \
     -e "$PLAT_AMD64" . >"$TMP/platdoc.txt" 2>/dev/null && [ -s "$TMP/platdoc.txt" ]; then
  check "documentation shows an amd64-only build command (not a build-file defect):"
  sed 's/^/           /' "$TMP/platdoc.txt" | head -5
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

# A --platform with nothing that sets GOARCH for the target: arm64 image, amd64 binary.
#
# Three things this must get right, each measured against a real repository:
#
#  1. COMMENTS DO NOT COUNT. payforadoption-go's Dockerfile mentions
#     `docker buildx build --platform linux/arm64` inside a `#` comment explaining why
#     a sibling script is used; grepping the raw file saw `--platform` and fired.
#  2. A LITERAL GOARCH COUNTS. That same Dockerfile does
#     `RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ...` - it hardcodes arm64
#     deliberately, so a bare `docker build` fails loudly instead of silently shipping
#     amd64. That is the most Graviton-ready form there is, and the check accused it
#     because it only recognized GOARCH=$TARGETARCH.
#  3. A CROSS-COMPILE WRAPPER COUNTS. containerd's release Dockerfile uses
#     tonistiigi/xx, where `xx-go --wrap` derives GOARCH from $TARGETPLATFORM.
XX_WRAPPER='xx-go|xx-info|xx-verify|xx-apt|xx-cc|xx-clang|--wrap|goreleaser|ko build|CC=\$\(xx-info\)'
GOARCH_SET='GOARCH[[:space:]]*=[[:space:]]*"?\$\{?TARGETARCH|GOARCH[[:space:]]*=[[:space:]]*"?(arm64|\$\{?GOARCH)'
for df in $(find . -name 'Dockerfile*' -not -path './vendor/*' -not -path './.git/*' 2>/dev/null); do
  # Strip comments before looking for anything. A Dockerfile comment starts with #.
  sed 's/[[:space:]]*#.*$//' "$df" >"$TMP/df.stripped" 2>/dev/null
  grep -q -- '--platform' "$TMP/df.stripped" 2>/dev/null || continue
  if grep -qE "$XX_WRAPPER" "$TMP/df.stripped" 2>/dev/null; then
    ok "$df uses --platform with a cross-compile wrapper (xx-go / TARGETARCH); verify the built binary's arch in Phase 3.3"
  elif grep -qE "$GOARCH_SET" "$TMP/df.stripped" 2>/dev/null; then
    ok "$df uses --platform and sets GOARCH for the target explicitly"
  else
    finding "$df uses --platform but nothing sets GOARCH for the target, and it uses no cross-compile wrapper (arm64 image, amd64 binary)"
  fi
done
# The inverse check, which is the one that actually matters for a repo like this: a
# Dockerfile that builds Go but never names an architecture at all gets the builder's.
# And a Dockerfile that DOES name it gets an explicit OK - this skill records the
# correct cases on purpose, so that nobody "fixes" them later.
for df in $(find . -name 'Dockerfile*' -not -path './vendor/*' -not -path './.git/*' 2>/dev/null); do
  sed 's/[[:space:]]*#.*$//' "$df" >"$TMP/df.stripped" 2>/dev/null
  grep -qE '^[[:space:]]*RUN[^#]*go build' "$TMP/df.stripped" 2>/dev/null || continue
  grep -q -- '--platform' "$TMP/df.stripped" 2>/dev/null && continue   # handled above
  if grep -qE "$GOARCH_SET" "$TMP/df.stripped" 2>/dev/null; then
    ok "$df sets GOARCH for the target explicitly in its go build"
  elif grep -qE "$XX_WRAPPER" "$TMP/df.stripped" 2>/dev/null; then
    ok "$df builds through a cross-compile wrapper"
  else
    check "$df runs 'go build' and names no architecture: the binary gets the BUILDER's arch. Fine under 'buildx --platform', broken under a bare 'docker build'"
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

grep -rl --include='*.go' 'cpu\.X86\.' . --exclude-dir=vendor --exclude-dir=testdata 2>/dev/null \
  | while read -r f; do
      grep -q 'cpu\.ARM64\.' "$f" || check "x86-only CPU dispatch (read the final else): $f"
    done

if grep -rqn --include='*.go' -E 'syscall\.SYS_|unix\.SYS_' . --exclude-dir=vendor --exclude-dir=testdata 2>/dev/null; then
  check "direct syscall constants (a missing one is a compile error; a numeric seccomp filter is silent):"
  grep -rn --include='*.go' -E 'syscall\.SYS_|unix\.SYS_' . --exclude-dir=vendor --exclude-dir=testdata 2>/dev/null \
    | sed 's/^/           /' | head -10
fi

if grep -rqn -iE 'AUDIT_ARCH_X86_64|SCMP_ARCH_X86_64' . --exclude-dir=.git --exclude-dir=vendor 2>/dev/null; then
  finding "seccomp/BPF pinned to an x86 architecture (fails open or closed on arm64):"
  grep -rn -iE 'AUDIT_ARCH_X86_64|SCMP_ARCH_X86_64' . --exclude-dir=.git --exclude-dir=vendor 2>/dev/null \
    | sed 's/^/           /' | head -5
fi

if grep -rqn --include='*.go' -E '\b4096\b' . --exclude-dir=vendor --exclude-dir=testdata 2>/dev/null; then
  check "hardcoded 4096 present; a finding only where it is used page-granularly (grade against the target's getconf PAGESIZE)"
fi

# Is the race detector run anywhere? Projects rarely spell it `go test -race` on one
# line. Measured: a Makefile with `gotestsum -- -race ./...` was reported as never
# running -race. Accepted forms, in every place a Go project configures its tests:
#   go test -race, gotestsum -- -race, ginkgo --race, TESTFLAGS ?= -race, GOFLAGS=-race,
#   Bazel rules_go `race = "on"` and --@io_bazel_rules_go//go/config:race
# in Makefiles, shell scripts, CI YAML (including .github/), justfile, Earthfile,
# magefiles and Bazel files. Comment lines do not count.
#
# Not running -race is an ADVISORY, not a FINDING: it is a gap in how the project is
# tested, not arm64 migration work, and exit criterion 9 runs the detector regardless.
find . \( -type d \( -name .git -o -name vendor -o -name node_modules -o -name testdata \) -prune \) -o -type f \
  \( -name Makefile -o -name GNUmakefile -o -name makefile -o -name '*.mk' -o -name '*.sh' -o -name '*.bash' \
     -o -name '*.yml' -o -name '*.yaml' -o -name justfile -o -name Justfile -o -name .justfile \
     -o -name Earthfile -o -name '*.bzl' -o -name BUILD -o -name BUILD.bazel -o -name .bazelrc \
     -o -name 'magefile*.go' -o -path '*/magefiles/*.go' \) -print 2>/dev/null >"$TMP/race.files"
RACE_RE='(^|[^A-Za-z0-9_-])--?race([^A-Za-z0-9_-]|$)|race[[:space:]]*=[[:space:]]*"on"|go/config:race'
: >"$TMP/race.hits"
if [ -s "$TMP/race.files" ]; then
  tr '\n' '\0' <"$TMP/race.files" | xargs -0 grep -nHE "$RACE_RE" 2>/dev/null \
    | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(#|//)' >"$TMP/race.hits"
fi
if [ -s "$TMP/race.hits" ]; then
  ok "-race is enabled in $(count_lines "$TMP/race.hits") place(s), e.g. $(head -1 "$TMP/race.hits" | cut -c1-120); run it on arm64 too (exit criterion 9)"
else
  advisory "no -race anywhere in the build or CI configuration - the weak-memory-order risk is UNMEASURED (exit criterion 9 runs it regardless)"
fi
}

# ---------------------------------------------------------------------- result
REPORT="$TMP/report.txt"
if [ $JSON -eq 1 ]; then
  scan_body >"$REPORT" 2>&1
else
  scan_body 2>&1 | tee "$REPORT"
fi
NF=$(grep -c '^FINDING ' "$REPORT" || true)
NA=$(grep -c '^ADVISORY ' "$REPORT" || true)
NC=$(grep -c '^CHECK ' "$REPORT" || true)
RC=0
[ "${NF:-0}" -gt 0 ] && RC=1
[ $STRICT -eq 1 ] && [ "${NA:-0}" -gt 0 ] && RC=1

footer() {
  head2 "Result"
  note "findings: $NF    advisories: $NA    checks: $NC    exit: $RC$([ $STRICT -eq 1 ] && echo ' (-strict)')"
  note ""
  note "A CHECK is a lead, not a verdict. Resolve every one before writing a PASS."
  note "Shape C blockers, cgo routes and the race result all require the full skill:"
  note "  phases/phase1-static-analysis.md, phase2-resolution.md, phase3-validation.md"
}

# JSON: built from the text report, so the two can never disagree. Each FINDING /
# ADVISORY / CHECK / OK line is one item; the indented lines under it are its details.
json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/\\\\t/g"; }
render_json() {
  tr -d '\000-\010\013\014\016-\037' <"$REPORT" | json_escape \
  | J_PROJECT="$(printf '%s' "$ROOT" | json_escape)" J_TAGS="$(printf '%s' "$TAGS" | json_escape)" \
    awk -v strict="$STRICT" -v nf="$NF" -v na="$NA" -v nc="$NC" -v rc="$RC" '
    function flush() {
      if (lvl == "") return
      printf "%s\n    {\"section\": \"%s\", \"level\": \"%s\", \"message\": \"%s\", \"details\": [%s]}", \
        (n++ ? "," : ""), sec, lvl, msg, det
      lvl = ""
    }
    BEGIN {
      printf "{\n  \"tool\": \"go_arch_scan\",\n  \"schema\": 1,\n  \"project\": \"%s\",\n  \"tags\": \"%s\",\n", ENVIRON["J_PROJECT"], ENVIRON["J_TAGS"]
      printf "  \"strict\": %s,\n  \"exit_code\": %d,\n", (strict + 0 ? "true" : "false"), rc
      printf "  \"summary\": {\"findings\": %d, \"advisories\": %d, \"checks\": %d},\n  \"items\": [", nf, na, nc
    }
    /^== .* ==$/                    { flush(); sec = substr($0, 4, length($0) - 6); next }
    /^(FINDING|ADVISORY|CHECK|OK) / { flush(); lvl = $1; msg = $0; sub(/^[A-Z]+ +/, "", msg); det = ""; next }
    /^[ \t]+[^ \t]/                 { if (lvl != "") { d = $0; sub(/^[ \t]+/, "", d); det = det (det == "" ? "" : ", ") "\"" d "\"" }; next }
                                    { flush() }
    END { flush(); printf "\n  ]\n}\n" }'
}

if [ $JSON -eq 1 ]; then
  footer >>"$REPORT"
  render_json >"$TMP/report.json"
  cat "$TMP/report.json"
  [ -n "$OUT" ] && cp "$TMP/report.json" "$OUT"
else
  footer | tee -a "$REPORT"
  [ -n "$OUT" ] && cp "$REPORT" "$OUT"
fi
exit $RC
