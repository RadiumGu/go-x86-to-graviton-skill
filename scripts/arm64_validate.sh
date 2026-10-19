#!/usr/bin/env bash
# arm64_validate.sh - run the Phase 3 build/vet/test/race matrix and write the logs
# under graviton-validation/raw/ with the canonical names the reports cite.
#
# It does NOT modify the project's source. It writes only inside
# graviton-validation/ and uses a GOBIN outside the tree, so `git add -A` on the
# project never picks up build output.
#
# What it can prove depends entirely on where it runs:
#   x86 host        -> the cross-build only (exit criterion 1)
#   arm64 hardware  -> build, vet, test and race (criteria 1,2,5,8,9,10,11)
# It prints which case applies and refuses to imply more than it measured.
#
# Usage:
#   ./arm64_validate.sh [PROJECT_DIR] [--cgo 0|1] [--count N] [--skip REGEX]
#                       [--build-cmd 'make release'] [--tags 'netgo,osusergo']
#
# Exit status:
#   0  every check that could run, passed
#   1  at least one check failed
#   2  cannot run (no Go toolchain, not a Go project)
#
# Compatible with bash 3.2 and later.

set -u

PROJECT="."
CGO=""
COUNT=1
SKIP=""
BUILD_CMD=""
TAGS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --cgo)       CGO="${2:-}"; shift 2 ;;
    --count)     COUNT="${2:-1}"; shift 2 ;;
    --skip)      SKIP="${2:-}"; shift 2 ;;
    --build-cmd) BUILD_CMD="${2:-}"; shift 2 ;;
    --tags)      TAGS="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          echo "unknown option: $1" >&2; exit 2 ;;
    *)           PROJECT="$1"; shift ;;
  esac
done

cd "$PROJECT" 2>/dev/null || { echo "not a directory: $PROJECT" >&2; exit 2; }
command -v go >/dev/null 2>&1 || { echo "go not found on PATH" >&2; exit 2; }
[ -f go.mod ] || [ -f go.work ] || { echo "no go.mod or go.work in $(pwd)" >&2; exit 2; }

RAW="graviton-validation/raw"
mkdir -p "$RAW" || exit 2
GOBIN_DIR="${TMPDIR:-/tmp}/graviton-bin.$$"
mkdir -p "$GOBIN_DIR"
cleanup() { rm -rf "$GOBIN_DIR"; }
trap cleanup EXIT INT TERM

HOSTARCH="$(uname -m)"
case "$HOSTARCH" in
  aarch64|arm64) NATIVE_ARM64=1 ;;
  *)             NATIVE_ARM64=0 ;;
esac

TAGFLAG=""
[ -n "$TAGS" ] && TAGFLAG="-tags=$TAGS"
SKIPFLAG=""
[ -n "$SKIP" ] && SKIPFLAG="-skip=$SKIP"

FAILED=0
report() { printf '%-44s %s\n' "$1" "$2"; }
fail()   { FAILED=$((FAILED+1)); report "$1" "FAIL   ($2)"; }
pass()   { report "$1" "PASS   ($2)"; }
notrun() { report "$1" "NOT RUN ($2)"; }

echo "arm64_validate - $(pwd)"
echo "host:      $HOSTARCH   go: $(go version | awk '{print $3}')"
echo "logs:      $RAW/"
if [ $NATIVE_ARM64 -eq 1 ]; then
  echo "capability: native arm64 - build, vet, test and race are all measurable here"
else
  echo "capability: NOT arm64 - only the cross-build is measurable. Criteria 2, 5, 8-13"
  echo "            will be reported NOT RUN. Re-run this on Graviton, Apple Silicon or"
  echo "            an arm64 CI runner to satisfy them. Emulation does NOT satisfy the"
  echo "            race criterion: QEMU does not reproduce arm64 memory ordering."
fi
if [ -z "$CGO" ]; then
  CGO="$(go env CGO_ENABLED)"
  echo "CGO_ENABLED: $CGO (inherited; pass --cgo to match the deployment)"
else
  echo "CGO_ENABLED: $CGO (given)"
fi
echo

# ------------------------------------------------- 1. cross-build (criterion 1)
# shellcheck disable=SC2086
if CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build $TAGFLAG ./... \
     >"$RAW/arm64-crossbuild.log" 2>&1; then
  pass "1  cross-build linux/arm64 (CGO off)" "$RAW/arm64-crossbuild.log"
else
  fail "1  cross-build linux/arm64 (CGO off)" "$RAW/arm64-crossbuild.log"
fi

# The x86 baseline, for classifying everything below as ARM64 vs PRE-EXISTING
# shellcheck disable=SC2086
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build $TAGFLAG ./... \
  >"$RAW/amd64-build.log" 2>&1
BASE_BUILD=$?
[ $BASE_BUILD -ne 0 ] && echo "   note: the x86 baseline build also fails - treat shared failures as PRE-EXISTING"

# -------------------------------------------- 2. native build (criterion 2)
if [ $NATIVE_ARM64 -eq 1 ]; then
  # shellcheck disable=SC2086
  if CGO_ENABLED="$CGO" GOBIN="$GOBIN_DIR" go build $TAGFLAG -o "$GOBIN_DIR/" ./... \
       >"$RAW/arm64-build.log" 2>&1; then
    pass "2  native arm64 build (CGO=$CGO)" "$RAW/arm64-build.log"
  else
    fail "2  native arm64 build (CGO=$CGO)" "$RAW/arm64-build.log"
  fi
else
  notrun "2  native arm64 build" "host is $HOSTARCH"
fi

# ------------------------------- 2b. the deployment's own build command
if [ -n "$BUILD_CMD" ]; then
  if [ $NATIVE_ARM64 -eq 1 ]; then
    if sh -c "$BUILD_CMD" >"$RAW/arm64-release-build.log" 2>&1; then
      pass "2b release build: $BUILD_CMD" "$RAW/arm64-release-build.log"
    else
      fail "2b release build: $BUILD_CMD" "$RAW/arm64-release-build.log"
    fi
  else
    notrun "2b release build" "host is $HOSTARCH"
  fi
else
  notrun "2b release build" "no --build-cmd given; go build ./... is NOT the release path"
fi

# ------------------------------------------------------ 5. go vet diff
if [ $NATIVE_ARM64 -eq 1 ]; then
  # shellcheck disable=SC2086
  CGO_ENABLED="$CGO" GOOS=linux GOARCH=arm64 go vet $TAGFLAG ./... >"$RAW/arm64-vet.log" 2>&1
  # go vet is static analysis, so GOARCH=amd64 IS a valid baseline here: it analyses
  # the amd64 build without executing anything. This is the one baseline that does not
  # need an x86 host.
  # shellcheck disable=SC2086
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go vet $TAGFLAG ./... >"$RAW/amd64-vet.log" 2>&1
  if diff -q "$RAW/amd64-vet.log" "$RAW/arm64-vet.log" >/dev/null 2>&1; then
    pass "5  go vet: no arm64-only findings" "identical to the x86 baseline"
  else
    fail "5  go vet: arm64-only findings" "diff $RAW/amd64-vet.log $RAW/arm64-vet.log"
  fi
else
  notrun "5  go vet diff" "host is $HOSTARCH"
fi

# --------------------------------------------------- 8. go test (criterion 8)
if [ $NATIVE_ARM64 -eq 1 ]; then
  # shellcheck disable=SC2086
  if CGO_ENABLED="$CGO" go test $TAGFLAG $SKIPFLAG ./... >"$RAW/arm64-test.log" 2>&1; then
    pass "8  go test on arm64" "$RAW/arm64-test.log"
  else
    fail "8  go test on arm64" "$RAW/arm64-test.log"
  fi
  # The x86 baseline for classification. On an arm64 host, `GOARCH=amd64 go test`
  # cross-compiles and cannot execute, so it produces a log that proves nothing -
  # run it only where it actually runs, and say so otherwise.
  if [ "$HOSTARCH" = "x86_64" ] || [ "$HOSTARCH" = "amd64" ]; then
    # shellcheck disable=SC2086
    CGO_ENABLED=0 go test $TAGFLAG $SKIPFLAG ./... >"$RAW/amd64-test.log" 2>&1
    echo "   x86 baseline (native): $RAW/amd64-test.log  (classify each failure ARM64 / PRE-EXISTING / INFRA)"
  else
    echo "   x86 baseline: NOT RUN on this $HOSTARCH host. Without it, ARM64 and"
    echo "                 PRE-EXISTING cannot be told apart - run this script on an x86"
    echo "                 host too, or under 'docker run --platform linux/amd64'."
  fi
else
  notrun "8  go test on arm64" "host is $HOSTARCH"
fi

# ------------------------------------------ 9. go test -race (criterion 9)
# The reason this skill exists. The DETECTOR is architecture-independent (measured:
# the same bug reported 3 races on both a c7g and a c7i), so this is worth running
# wherever it runs. What arm64 adds is interleaving diversity, and the fact that a
# race here is a 22-38% production event instead of 0 in 1.2e9 samples.
if [ $NATIVE_ARM64 -eq 0 ]; then
  notrun "9  go test -race on arm64" "host is $HOSTARCH - run it here anyway for detection"
elif ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1; then
  notrun "9  go test -race on arm64" "no C compiler: the race detector cannot build"
else
  # shellcheck disable=SC2086
  CGO_ENABLED=1 go test -race -count="$COUNT" $TAGFLAG $SKIPFLAG ./... \
    >"$RAW/arm64-race.log" 2>&1
  RACE_RC=$?
  NRACE=$(grep -c 'WARNING: DATA RACE' "$RAW/arm64-race.log" 2>/dev/null)
  NRACE=${NRACE:-0}; [ "$NRACE" -eq "$NRACE" ] 2>/dev/null || NRACE=0
  if [ "$NRACE" -gt 0 ]; then
    fail "9  go test -race on arm64" "$NRACE DATA RACE report(s) - see $RAW/arm64-race.log"
    echo
    echo "   A data race is BLOCKING. It is a pre-existing defect, and on Graviton it is a"
    echo "   22-38% event where on x86 it was 0 in 1.2e9 samples (measured, see the skill's"
    echo "   README). Copy the FULL detector output into the report - both stacks are the fix."
    echo "   Never work around it with a sleep, a reorder or a runtime setting."
    echo
    # The x86 baseline decides how the finding is framed - but it can only be obtained
    # by EXECUTING on x86. `GOARCH=amd64 go test` on an arm64 host cross-compiles and
    # cannot run the test binary, so it reports 0 races because nothing executed.
    # Reading that 0 as "arm64 only" is exactly the empty-result-as-fact error this
    # skill exists to prevent, and an earlier version of this script made it.
    if [ "$HOSTARCH" = "x86_64" ] || [ "$HOSTARCH" = "amd64" ]; then
      CGO_ENABLED=1 go test -race -count="$COUNT" $TAGFLAG $SKIPFLAG ./... \
        >"$RAW/amd64-race.log" 2>&1
      NB=$(grep -c 'WARNING: DATA RACE' "$RAW/amd64-race.log" 2>/dev/null); NB=${NB:-0}
      echo "   x86 baseline (native, this host): $NB race report(s) in $RAW/amd64-race.log"
      if [ "$NB" -gt 0 ]; then
        echo "   -> reachable on both: the project has simply never run -race"
      else
        echo "   -> not observed on x86 in $COUNT run(s). Raise --count before concluding"
        echo "      'arm64 only': the detector is architecture-independent, so a race it"
        echo "      finds on arm64 is usually findable on x86 too, just less often."
      fi
    else
      notrun "   x86 baseline race comparison" "this host is $HOSTARCH"
      echo "   The comparison needs a run that EXECUTES on x86: a real x86 host, an x86 CI"
      echo "   runner, or \`docker run --platform linux/amd64\`. Setting GOARCH=amd64 here"
      echo "   only cross-compiles - it would report 0 races because nothing ran, and"
      echo "   reporting that as 'arm64 only' would be wrong."
      echo "   Until then the finding is: a data race, blocking, architecture of origin"
      echo "   UNDETERMINED."
    fi
  elif [ $RACE_RC -ne 0 ]; then
    fail "9  go test -race on arm64" "no race, but tests failed - see $RAW/arm64-race.log"
  else
    pass "9  go test -race on arm64" "no race observed in $COUNT run(s) of the suite"
    echo "   (evidence, not proof: the detector reports only the races it observes)"
  fi
fi

# ------------------------------------------------ 12/13. binary and startup
if [ $NATIVE_ARM64 -eq 1 ] && command -v file >/dev/null 2>&1; then
  found=0
  for b in "$GOBIN_DIR"/*; do
    [ -f "$b" ] || continue
    found=1
    d=$(file -b "$b" 2>/dev/null)
    case "$d" in
      *aarch64*) pass "13 $(basename "$b"): aarch64" "$d" ;;
      *)         fail "13 $(basename "$b"): not aarch64" "$d" ;;
    esac
    if command -v ldd >/dev/null 2>&1; then
      ldd "$b" 2>/dev/null | awk '{print $3}' | grep -v '^$' \
        | while read -r l; do
            ld=$(file -b "$l" 2>/dev/null)
            case "$ld" in
              *aarch64*) : ;;
              *) echo "   FINDING linked library is not aarch64: $l ($ld)" ;;
            esac
          done
    fi
  done
  [ $found -eq 0 ] && notrun "13 binary architecture" "no binary produced (library-only module?)"
else
  notrun "13 binary architecture" "host is $HOSTARCH, or 'file' unavailable"
fi

echo
echo "== Result =="
echo "failed checks: $FAILED"
if [ $NATIVE_ARM64 -eq 0 ]; then
  echo
  echo "This run measured ONE exit criterion. Record every NOT RUN above as NOT RUN in"
  echo "00-summary.md - not as PASS. A cross-build proves the code is arm64-buildable and"
  echo "nothing about how it behaves there."
fi
echo
echo "Startup validation (criterion 12) is not automated here: run the application and"
echo "confirm runtime.GOARCH reports arm64, then serve one real request."
echo "See phases/phase3-validation.md section 3.4."

[ $FAILED -gt 0 ] && exit 1
exit 0
