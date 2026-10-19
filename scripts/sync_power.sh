#!/usr/bin/env bash
# sync_power.sh - regenerate POWER.md from SKILL.md.
#
# The two entry points must carry the SAME body and DIFFERENT frontmatter:
# SKILL.md uses the Agent Skills format (name, description, metadata), POWER.md
# uses the Kiro Powers format (name, displayName, description, keywords, author).
# This script keeps the Kiro frontmatter and replaces everything after it with
# SKILL.md's body, so the two cannot drift.
#
# Run from the skill directory, after editing SKILL.md:
#   ./scripts/sync_power.sh
#
# Exit 0 on success, 1 if either file is missing or malformed.

set -eu

cd "$(dirname "$0")/.."
[ -f SKILL.md ] || { echo "SKILL.md not found in $(pwd)" >&2; exit 1; }

POWER_FRONTMATTER=$(cat <<'EOF'
---
name: go-x86-to-graviton
displayName: "Go x86 to Graviton Migration"
description: "Validates Go application compatibility with AWS Graviton (ARM64/aarch64). Go module dependencies carry no per-architecture artifacts, so this transformation targets the four places Go migrations actually break: cgo and the C libraries it links, amd64-only build constraints and assembly with no arm64 counterpart, non-Go artifacts (committed binaries, binaries downloaded by scripts or Dockerfiles, base images without an arm64 manifest), and behavioral differences that compile cleanly then fail at runtime - data races exposed by arm64's weak memory ordering, FMA-fused floating-point results, direct syscall numbers and hardcoded page sizes. Performs static analysis, applies ARM64-required build and code fixes, documents Graviton runtime recommendations, and validates build, vet, race, tests and startup on ARM64."
keywords: ["go", "golang", "graviton", "arm64", "aarch64", "migration", "cgo", "build constraints", "assembly", "data race", "memory model", "cross-compile", "multi-arch", "lambda", "ecs", "eks"]
author: "RadiumGu"
---
EOF
)

# Body = everything after SKILL.md's closing frontmatter delimiter.
# Find the line number of the second '---' at the start of a line.
END=$(grep -n '^---[[:space:]]*$' SKILL.md | sed -n 2p | cut -d: -f1)
[ -n "${END:-}" ] || { echo "SKILL.md has no closing frontmatter delimiter" >&2; exit 1; }

{
  printf '%s\n' "$POWER_FRONTMATTER"
  tail -n "+$((END + 1))" SKILL.md
} > POWER.md.tmp

mv POWER.md.tmp POWER.md
echo "POWER.md regenerated from SKILL.md ($(wc -l < POWER.md | tr -d ' ') lines)"
