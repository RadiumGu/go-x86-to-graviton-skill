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
# A literal GOARCH=arm64 is a valid way to set the target; a comment mentioning
# --platform is not a --platform usage. Both measured on payforadoption-go.
assert_lacks "literal GOARCH=arm64 NOT accused"     "$OUT" 'FINDING.*Dockerfile\.literal'
assert_has   "literal GOARCH=arm64 recognized"      "$OUT" 'OK.*Dockerfile\.literal.*GOARCH'
assert_lacks "README amd64 command is not a FINDING" "$OUT" 'FINDING.*docs/README\.md'
assert_has   "README amd64 command is a CHECK"       "$OUT" 'CHECK.*documentation shows an amd64-only build'
# build config
assert_has "GOARCH=amd64 in Makefile reported" "$OUT" 'FINDING.*GOARCH hardcoded to amd64'
assert_has "GOAMD64 noted"                     "$OUT" 'CHECK.*GOAMD64'
assert_has "goreleaser missing arm64 reported" "$OUT" 'FINDING.*goarch does not include arm64'
# artifacts
assert_has "x86 download URL aggregated" "$OUT" 'FINDING.*x86-hardcoded download URLs: [0-9]+ occurrence'
# shapes
assert_has "Shape A recognized" "$OUT" 'OK.*Shape A.*internal/hash'
assert_has "stub fallback reported" "$OUT" 'FINDING.*panic rather than implement'
# race gate: an ADVISORY, not a FINDING - it is a testing gap, not migration work, and
# counting it as a finding made exit 1 the answer for nearly every repository
assert_has   "missing -race reported as an advisory" "$OUT" '^ADVISORY no -race anywhere'
assert_lacks "missing -race is not a FINDING"        "$OUT" '^FINDING.*-race'
# pure-cgo package must NOT be called Shape C (only visible with a toolchain)
if grep -q 'OK  *resolved [0-9]* packages' "$OUT"; then
  assert_has   "pure-cgo package distinguished from Shape C" "$OUT" 'resolve ONLY with cgo enabled'
  assert_lacks "pure-cgo package not labelled Shape C"       "$OUT" 'Shape C.*purecgo'
else
  echo "  SKIP  no Go toolchain - the cgo-off disambiguation needs one"
fi

echo
echo "=== 4. go_arch_scan on the clean fixture ==="
OUT2=$(mktemp); cd tests/fixtures/clean || exit 2
"$SCAN" . >"$OUT2" 2>&1; RC2=$?
cd "$ROOT" || exit 2
assert_exit "exit 0 on a clean fixture" "$RC2" 0
assert_lacks "no findings at all"       "$OUT2" '^FINDING'
assert_has   "-race presence recognized" "$OUT2" '^OK +-race is enabled in 1 place.*Makefile'

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
  assert_has   "race check executed, not skipped" "$OUT5" '^9 +go test -race.*(FAIL|PASS)'
  assert_lacks "race check not reported NOT RUN"   "$OUT5" '^9 +go test -race.*NOT RUN'
  assert_has   "known race in the fixture reported" "$OUT5" 'DATA RACE report'
  assert_lacks "no stale 'emulation does not count' claim" "$OUT5" 'emulation does NOT satisfy|QEMU does not reproduce'
  assert_lacks "no cross-compiled baseline passed off as a baseline" "$OUT5" "x86 baseline: 0 race report"
  rm -f "$OUT5"
else
  echo "  SKIP  no go and/or C compiler on this host - arm64_validate not exercised"
fi

echo
echo "=== 8. docs agree with the measurement: emulation and x86 count for the race check ==="
# Test 7 pins the validator's OUTPUT. The retracted claim also survived in the documents
# an agent actually reads: SKILL.md's entry criterion 5 and Notes said the opposite of
# exit criterion 9 two screens away. Grep every shipped document for the old wording.
OUT6=$(mktemp)
grep -rnE 'not evidence for (the race check|exit criterion 9)|[Ee]mulation is not the race check|refuses to satisfy under emulation|模拟不等于竞争检查|不能作为退出条件 9 的证据|拒绝在模拟环境下认为该条件满足|退出条件 9 记 `NOT RUN`|cross-build only \(exit criterion 1\)|measured ONE exit criterion|must be real arm64 hardware|NOT RUN - no arm64 hardware|mandatory, on real arm64 hardware$|on real arm64 hardware \(criterion 9\)' \
  SKILL.md POWER.md README.md summaries.md docs/*.md phases/*.md document_references/*.md scripts/*.sh examples >"$OUT6" 2>/dev/null
assert_lacks "no document says emulation is not evidence for criterion 9" "$OUT6" '.'
rm -f "$OUT6"

echo
echo "=== 9. directories and modules follow the go command's rules ==="
# Each assertion is a defect measured on the previous scanner: it enumerated directories
# with `find -name '*.go'` and resolved only the root module.
if command -v go >/dev/null 2>&1; then
  OUT7=$(mktemp); cd tests/fixtures/layout || exit 2
  "$SCAN" . >"$OUT7" 2>&1; RC7=$?
  cd "$ROOT" || exit 2
  assert_lacks "testdata/ is not a package"           "$OUT7" '^FINDING.*testdata'
  assert_lacks "_scratch/ is not a package"           "$OUT7" '^FINDING.*_scratch'
  assert_lacks ".cache/ is not a package"             "$OUT7" '^FINDING.*\.cache'
  assert_has   "nested module is resolved"            "$OUT7" '^OK +resolved [0-9]+ packages .* in 2 of 2 module'
  assert_has   "Shape C in the nested module found"   "$OUT7" '^FINDING +Shape C \(reachable, blocks the build\): example.com/layout/svc/simd .*imported by: example.com/layout/svc'
  assert_lacks "reachable Shape C not double-reported" "$OUT7" 'latent until imported.*svc/simd'
  assert_lacks "reachable Shape C not repeated as a set difference" "$OUT7" 'resolve on amd64 but NOT on arm64'
  assert_exit  "exit 1: the nested module has a blocker" "$RC7" 1
  # build tags
  assert_has   "unevaluated build tag named"          "$OUT7" '^CHECK +build tags used in this tree were NOT evaluated.*prod'
  assert_lacks "untagged scan reports no Shape C in internal/fast" "$OUT7" '^FINDING.*internal/fast'
  OUT8=$(mktemp); cd tests/fixtures/layout || exit 2
  "$SCAN" -tags prod . >"$OUT8" 2>&1
  cd "$ROOT" || exit 2
  assert_has   "-tags prod exposes the tag-gated Shape C" "$OUT8" '^FINDING +Shape C.*internal/fast'
  assert_lacks "-tags prod: tag no longer unevaluated"    "$OUT8" 'NOT evaluated.*prod'
  # race detection through gotestsum
  assert_has   "gotestsum -- -race recognized"        "$OUT7" '^OK +-race is enabled.*Makefile'
  rm -f "$OUT7" "$OUT8"

  OUT9=$(mktemp); cd tests/fixtures/workspace || exit 2
  "$SCAN" . >"$OUT9" 2>&1
  cd "$ROOT" || exit 2
  assert_lacks "go.work root resolves"                "$OUT9" 'RESOLUTION FAILED'
  assert_has   "Shape C in a workspace module found"  "$OUT9" '^FINDING +Shape C \(reachable.*example.com/m1/simd'
  assert_has   "module outside go.work resolved standalone" "$OUT9" 'module \./m2 is not listed in go.work'
  assert_has   "both workspace modules resolved"      "$OUT9" 'in 2 of 2 module'
  rm -f "$OUT9"
else
  echo "  SKIP  no Go toolchain - module and directory resolution not exercised"
fi

echo
echo "=== 10. command line behaves like a Go tool ==="
cd tests/fixtures/clean || exit 2
"$SCAN" --tag prod . >/dev/null 2>&1;   assert_exit "unknown flag is an error, not ignored" $? 2
"$SCAN" . ../broken >/dev/null 2>&1;    assert_exit "two project directories is an error"   $? 2
"$SCAN" -tags >/dev/null 2>&1;          assert_exit "-tags without a value is an error"     $? 2
"$SCAN" -h >/dev/null 2>&1;             assert_exit "-h exits 0"                            $? 0
OD=$(mktemp -d)
"$SCAN" -o "$OD/scan.txt" . >/dev/null 2>&1
assert_has "-o FILE writes the report"      "$OD/scan.txt" '^findings: [0-9]+ +advisories'
"$SCAN" -json -o "$OD" . >"$OD/stdout.json" 2>/dev/null; RCJ=$?
cd "$ROOT" || exit 2
if python3 - "$OD/go-arch-scan.json" "$RCJ" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["tool"] == "go_arch_scan" and d["schema"] == 1
assert set(d["summary"]) == {"findings", "advisories", "checks"}
assert d["exit_code"] == int(sys.argv[2]), (d["exit_code"], sys.argv[2])
n = sum(1 for i in d["items"] if i["level"] == "FINDING")
assert n == d["summary"]["findings"], (n, d["summary"])
assert all(i["level"] in ("FINDING", "ADVISORY", "CHECK", "OK") for i in d["items"])
PY
then ok "-json is valid JSON, consistent with its own summary and the exit status"
else bad "-json output"; fi
if cmp -s "$OD/stdout.json" "$OD/go-arch-scan.json"; then ok "-json -o DIR writes DIR/go-arch-scan.json, same as stdout"
else bad "-json -o DIR"; fi
rm -rf "$OD"

echo
echo "=== 11. exit status: advisories do not fail the scan unless -strict ==="
T=$(mktemp -d); cp -R tests/fixtures/clean/. "$T/"
printf 'test:\n\tgo test ./...\n' >"$T/Makefile"     # no -race: one ADVISORY, no FINDING
OUT10=$(mktemp)
"$SCAN" "$T" >"$OUT10" 2>&1; RC10=$?
assert_has  "the advisory is present"         "$OUT10" '^ADVISORY'
assert_exit "advisory only -> exit 0"         "$RC10" 0
"$SCAN" -strict "$T" >/dev/null 2>&1;  assert_exit "advisory with -strict -> exit 1" $? 1
rm -rf "$T" "$OUT10"

echo
echo "=== 12. shipped instructions keep the user's repository clean ==="
# The skill used to tell the agent to `git add -A` on the user's current branch, which
# sweeps in their uncommitted work and untracked files and puts graviton-validation/
# into the migration PR. Any remaining instruction to do so is a regression; lines that
# say NOT to are fine.
OUT11=$(mktemp)
grep -rnE 'git add (-A|--all|\.)([[:space:]]|$|&|;|`)' SKILL.md POWER.md phases/*.md document_references/*.md \
  docs/*.md README.md 2>/dev/null | grep -viE 'never|not |NOT|不要|禁止|instead of' >"$OUT11"
assert_lacks "no instruction to git add -A / git add ." "$OUT11" '.'
grep -n 'git switch -c\|git checkout -b' SKILL.md >"$OUT11"
assert_has   "SKILL.md works on its own branch" "$OUT11" '.'
grep -n 'status --porcelain' SKILL.md >"$OUT11"
assert_has   "SKILL.md refuses a dirty work tree" "$OUT11" '.'
grep -n 'info/exclude' SKILL.md >"$OUT11"
assert_has   "SKILL.md keeps graviton-validation/ out of commits" "$OUT11" '.'
rm -f "$OUT11"

echo
echo "=== 13. helper scripts need no python ==="
OUT12=$(mktemp)
grep -nE '^[^#]*python' scripts/*.sh >"$OUT12" 2>/dev/null     # code, not comments
assert_lacks "no python in scripts/" "$OUT12" '.'
rm -f "$OUT12"

rm -f "$OUT" "$OUT2" "$OUT3" "$OUT4"
echo
echo "================================"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
