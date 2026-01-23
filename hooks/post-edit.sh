#!/usr/bin/env bash
# Post-edit hook: Verify state after modifications
# Usage: ./post-edit.sh [domain] [base-branch]
# Example: ./post-edit.sh authz develop
# Env: BRANCH=develop ./post-edit.sh authz

set -euo pipefail

DOMAIN="${1:-authz}"
BASE_BRANCH="${2:-${BRANCH:-develop}}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="/tmp/claude-baseline/post/${DOMAIN}/${TIMESTAMP}"
RESULT_FILE="$OUTPUT_DIR/result.txt"

mkdir -p "$OUTPUT_DIR"

echo "=== Verifying edits for domain: $DOMAIN ==="
echo "Base branch: $BASE_BRANCH"
echo "Output dir: $OUTPUT_DIR"

PASS=0
FAIL=0
FAILED_CHECKS=""

# Lint check (uses BRANCH for new-code detection)
echo "--- Lint Check ---"
if BRANCH="$BASE_BRANCH" make check-python-lint-new-code > "$OUTPUT_DIR/lint.txt" 2>&1; then
    echo "Lint: PASS"
    ((PASS++)) || true
else
    echo "Lint: FAIL (see $OUTPUT_DIR/lint.txt)"
    FAILED_CHECKS="${FAILED_CHECKS} lint"
    ((FAIL++)) || true
fi

# Type check (uses BRANCH for new-code detection)
echo "--- Type Check ---"
if BRANCH="$BASE_BRANCH" make check-python-types-new-code > "$OUTPUT_DIR/types.txt" 2>&1; then
    echo "Types: PASS"
    ((PASS++)) || true
else
    echo "Types: FAIL (see $OUTPUT_DIR/types.txt)"
    FAILED_CHECKS="${FAILED_CHECKS} types"
    ((FAIL++)) || true
fi

# Tests (path-scoped, always deterministic)
echo "--- Tests (path-scoped) ---"
if make test ARGS="tests/unit/services/${DOMAIN}/" > "$OUTPUT_DIR/tests.txt" 2>&1; then
    echo "Tests: PASS"
    ((PASS++)) || true
else
    echo "Tests: FAIL (see $OUTPUT_DIR/tests.txt)"
    FAILED_CHECKS="${FAILED_CHECKS} tests"
    ((FAIL++)) || true
fi

# Summary
echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "Output directory: $OUTPUT_DIR"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "=== FAILED CHECKS === $FAILED_CHECKS"
    echo ""
    echo "To debug, inspect these files:"
    for check in $FAILED_CHECKS; do
        if [ -f "$OUTPUT_DIR/${check}.txt" ]; then
            echo "  $OUTPUT_DIR/${check}.txt"
        fi
    done
    echo ""
    echo "RESULT: FAIL" | tee "$RESULT_FILE"
    exit 1
else
    echo "RESULT: PASS" | tee "$RESULT_FILE"
    exit 0
fi
