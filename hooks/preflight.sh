#!/usr/bin/env bash
# preflight.sh - Guard script to prevent scope creep
# Refuses to proceed if repo has changes outside .claude/local/

set -euo pipefail

echo "=== Preflight Check ==="

# Ensure we're in a git repo
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[FAIL] Not in a git repository"
    exit 1
fi

# Check for changes outside .claude/local/
DIRTY_PATHS=$(git status --porcelain 2>/dev/null | grep -v "^.. .claude/local/" | grep -v "^?? .claude/local/" || true)

if [[ -n "$DIRTY_PATHS" ]]; then
    echo ""
    echo "========================================"
    echo "STOP: Repo has changes outside .claude/local/"
    echo "========================================"
    echo ""
    echo "Dirty paths:"
    echo "$DIRTY_PATHS"
    echo ""
    echo "This tooling is scoped to .claude/local/** only."
    echo "Stash or commit other changes before running."
    echo ""
    exit 1
fi

# Optional: show current branch for awareness
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
echo "Branch: $BRANCH"
echo "Status: Clean (no changes outside .claude/local/)"
echo "=== Preflight OK ==="
echo ""
