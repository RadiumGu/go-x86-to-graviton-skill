#!/usr/bin/env bash
# run_tests.sh - regression tests for the skill's helper scripts.
#
# Each case asserts a specific line of output, not just an exit status, so a
# heuristic that silently stops firing is caught. Every assertion here exists
# because the corresponding defect was actually shipped and then found on a
# real repository - the commit log names which one.
#
# Usage: ./tests/run_tests.sh
# Exit 0 all passed, 1 some failed.

set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$(pwd)
SCAN="$ROOT/scripts/go_arch_scan.sh"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

# assert_has <label> <file> <regex>
assert_has() {
  if grep -qE "$3" "$2" 2>/dev/null; then ok "$1"; else
    bad "$1"; printf '        expected to match: %s\n' "$3"; fi
}
# assert_lacks <label> <file> <regex>
assert_lacks() {
  if grep -qE "$3" "$2" 2>/dev/null; then
    bad "$1"; printf '        unexpectedly matched: %s\n' "$3"
    grep -nE "$3" "$2" | sed 's/^/          /' | head -3
  else ok "$1"; fi
}
assert_exit() {
  if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (exit $2, want $3)"; fi
}

echo "=== 0. shell syntax ==="
for f in scripts/*.sh tests/run_tests.sh; do
  if bash -n "$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done

echo
echo "=== 1. entry points cannot drift ==="
SE=$(grep -n '^---[[:space:]]*$' SKILL.md | sed -n 2p | cut -d: -f1)
PE=$(grep -n '^---[[:space:]]*$' POWER.md | sed -n 2p | cut -d: -f1)
if diff -q <(tail -n "+$((SE+1))" SKILL.md) <(tail -n "+$((PE+1))" POWER.md) >/dev/null 2>&1; then
  ok "SKILL.md and POWER.md bodies identical"
else
  bad "SKILL.md and POWER.md bodies differ - run ./scripts/sync_power.sh"
fi

echo
echo "=== 2. relative links resolve ==="
if python3 - <<'PY'
import os, re, sys
bad = 0
for root, dirs, files in os.walk("."):
    if ".git" in root: continue
    for f in files:
        if not f.endswith(".md"): continue
        p = os.path.join(root, f)
        for m in re.finditer(r'\[([^\]]*)\]\(([^)]+)\)', open(p, encoding="utf-8").read()):
            t = m.group(2)
            if t.startswith(("http", "#", "mailto")): continue
            t = t.split("#")[0]
            if not t: continue
            if not os.path.exists(os.path.normpath(os.path.join(root, t))):
                print(f"BROKEN  {p}  ->  {m.group(2)}"); bad += 1
sys.exit(1 if bad else 0)
PY
then ok "all relative markdown links resolve"; else bad "broken relative links"; fi

echo
echo "=== 3. go_arch_scan on the broken fixture ==="
OUT=$(mktemp); cd tests/fixtures/broken || exit 2
"$SCAN" . >"$OUT" 2>&1; RC=$?
cd "$ROOT" || exit 2
assert_exit "exit 1 on a fixture with findings" "$RC" 1

# cgo flags - must catch the BLOCK-COMMENT form, not only `// #cgo`
assert_has "x86 #cgo flag in a /* */ block" "$OUT" 'FINDING.*x86-only flags in #cgo'
# the constraint may sit below a license header: a head -5 check misses it
assert_lacks "constraint at line 8 not reported as unconstrained" "$OUT" 'unconstrained .s file.*stub\.s'
assert_has   "genuinely unconstrained .s IS reported" "$OUT" 'unconstrained .s file.*unconstrained\.s'
# a GOOS filename suffix is a constraint
assert_lacks "GOOS-suffixed .s skipped" "$OUT" 'sys_darwin\.s'
# Dockerfile: the plain one is a finding, the xx one is not
assert_has   "--platform=linux/amd64 reported" "$OUT" 'FINDING.*--platform=linux/amd64'
assert_lacks "xx-go wrapper NOT accused" "$OUT" 'FINDING.*Dockerfile\.xx'
assert_has   "xx-go wrapper recognized" "$OUT" 'OK.*Dockerfile\.xx.*cross-compile wrapper'
# build config
assert_has "GOARCH=amd64 in Makefile reported" "$OUT" 'FINDING.*GOARCH hardcoded to amd64'
assert_has "GOAMD64 noted"                     "$OUT" 'CHECK.*GOAMD64'
assert_has "goreleaser missing arm64 reported" "$OUT" 'FINDING.*goarch does not include arm64'
# artifacts
assert_has "x86 download URL aggregated" "$OUT" 'FINDING.*x86-hardcoded download URLs: [0-9]+ occurrence'
# shapes
assert_has "Shape A recognized" "$OUT" 'OK.*Shape A.*internal/hash'
assert_has "stub fallback reported" "$OUT" 'FINDING.*panic rather than implement'
# race gate
assert_has "missing -race reported" "$OUT" "FINDING.*no 'go test -race' anywhere"

echo
echo "=== 4. go_arch_scan on the clean fixture ==="
OUT2=$(mktemp); cd tests/fixtures/clean || exit 2
"$SCAN" . >"$OUT2" 2>&1; RC2=$?
cd "$ROOT" || exit 2
assert_exit "exit 0 on a clean fixture" "$RC2" 0
assert_lacks "no findings at all"       "$OUT2" '^FINDING'
assert_has   "-race presence recognized" "$OUT2" "OK.*'go test -race' appears"

echo
echo "=== 5. not-a-Go-project ==="
OUT3=$(mktemp); T=$(mktemp -d)
"$SCAN" "$T" >"$OUT3" 2>&1; RC3=$?
rmdir "$T" 2>/dev/null
assert_exit "exit 2 on a non-Go directory" "$RC3" 2

echo
echo "=== 6. failed resolution must NOT print an all-clear ==="
# Hermetic: stub a `go` that fails the way the real one does when HOME is unset, so the
# branch is exercised without needing a toolchain. This is the exact message a real
# go1.27.2 produced under SSM Run Command, and the defect it caught was the script
# printing "OK no reachable Shape C package" from the resulting empty capture.
STUB=$(mktemp -d)
cat > "$STUB/go" <<'STUBEOF'
#!/bin/sh
case "$1" in
  version) echo "go version go1.27.2 linux/arm64"; exit 0 ;;
  env)     echo ""; exit 0 ;;
esac
echo "build cache is required, but could not be located: GOCACHE is not defined and neither \$XDG_CACHE_HOME nor \$HOME are defined" >&2
exit 1
STUBEOF
chmod +x "$STUB/go"
OUT4=$(mktemp); cd tests/fixtures/broken || exit 2
PATH="$STUB:$PATH" bash "$SCAN" . >"$OUT4" 2>&1 || true
cd "$ROOT" || exit 2; rm -rf "$STUB"
assert_has   "resolution failure detected"              "$OUT4" 'RESOLUTION FAILED'
assert_has   "cause named (no HOME/GOCACHE)"            "$OUT4" 'cause: no HOME/GOCACHE/GOMODCACHE'
assert_has   "fix offered"                              "$OUT4" 'fix: +export HOME='
assert_lacks "no Shape C all-clear from a failed capture" "$OUT4" 'OK +no reachable Shape C'
assert_lacks "no sweep all-clear from a failed capture"   "$OUT4" 'OK +per-directory sweep'
assert_lacks "no pure-Go all-clear from a failed capture" "$OUT4" 'OK +no package in the resolved set uses cgo'

echo
echo "=== 7. arm64_validate: the race check runs on EVERY host ==="
# Measured on a c7i.2xlarge: an earlier version reported criterion 9 as NOT RUN on
# x86 and printed "emulation does not satisfy the race criterion", both contradicted
# by the measurement that the detector is architecture-independent.
VAL="$ROOT/scripts/arm64_validate.sh"
if command -v go >/dev/null 2>&1 && command -v cc >/dev/null 2>&1; then
  OUT5=$(mktemp); cd tests/memory-model || exit 2
  bash "$VAL" . --cgo 1 --count 1 >"$OUT5" 2>&1 || true
  cd "$ROOT" || exit 2
  rm -rf tests/memory-model/graviton-validation
  # fail()/pass() print the LABEL first, then the verdict - assert that order.
  assert_has   "race check executed, not skipped" "$OUT5" '^9 +go test -race[^\n]*(FAIL|PASS)'
  assert_lacks "race check not reported NOT RUN"   "$OUT5" '^9 +go test -race[^\n]*NOT RUN'
  assert_has   "known race in the fixture reported" "$OUT5" 'DATA RACE report'
  assert_lacks "no stale 'emulation does not count' claim" "$OUT5" 'emulation does NOT satisfy|QEMU does not reproduce'
  assert_lacks "no cross-compiled baseline passed off as a baseline" "$OUT5" "x86 baseline: 0 race report"
  rm -f "$OUT5"
else
  echo "  SKIP  no go and/or C compiler on this host - arm64_validate not exercised"
fi

rm -f "$OUT" "$OUT2" "$OUT3" "$OUT4"
echo
echo "================================"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
