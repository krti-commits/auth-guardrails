#!/usr/bin/env bash
# Pre-edit hook: Capture baseline state before modifications
# Usage: ./pre-edit.sh [domain] [base-branch]
# Example: ./pre-edit.sh authz develop
# Env: BRANCH=develop ./pre-edit.sh authz

set -euo pipefail

DOMAIN="${1:-authz}"
BASE_BRANCH="${2:-${BRANCH:-develop}}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="/tmp/claude-baseline/pre/${DOMAIN}/${TIMESTAMP}"

mkdir -p "$OUTPUT_DIR"

echo "=== Capturing baseline for domain: $DOMAIN ==="
echo "Base branch: $BASE_BRANCH"
echo "Timestamp: $TIMESTAMP"
echo "Output dir: $OUTPUT_DIR"

# Capture git state
echo "--- Git Status ---"
git diff --stat > "$OUTPUT_DIR/diff.txt" 2>&1 || true
git status --short > "$OUTPUT_DIR/status.txt" 2>&1 || true

# Run path-scoped tests (always deterministic, doesn't depend on branch diff)
echo "--- Running Tests (path-scoped) ---"
if make test ARGS="tests/unit/services/${DOMAIN}/" > "$OUTPUT_DIR/tests.txt" 2>&1; then
    echo "Tests: PASS"
    echo "PASS" > "$OUTPUT_DIR/tests_result.txt"
else
    echo "Tests: FAIL (or no tests found)"
    echo "FAIL" > "$OUTPUT_DIR/tests_result.txt"
fi

echo ""
echo "Baseline captured to: $OUTPUT_DIR"
echo "Files created:"
ls -la "$OUTPUT_DIR"/*.txt 2>/dev/null || echo "  (none)"
