#!/usr/bin/env bash
# Post-edit hook: Verify state after modifications
# Usage: ./post-edit.sh [domain] [base-branch]
# Example: ./post-edit.sh auth develop
# Env: BRANCH=develop ./post-edit.sh auth
#
# Domains:
#   auth    - Full auth surface (auth + authz services, guards, dependencies)
#   authz   - Authorization only (legacy, maps to auth)

set -euo pipefail

DOMAIN="${1:-auth}"
BASE_BRANCH="${2:-${BRANCH:-develop}}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="/tmp/claude-baseline/post/${DOMAIN}/${TIMESTAMP}"
RESULT_FILE="$OUTPUT_DIR/result.txt"

# Map domain to test paths
get_test_paths() {
    local domain="$1"
    case "$domain" in
        auth|authz)
            # Full auth surface: auth service, authz service, guards, integration tests
            echo "tests/unit/services/auth/ tests/unit/services/authz/ tests/integration/services/auth/"
            ;;
        *)
            # Default: single domain path
            echo "tests/unit/services/${domain}/"
            ;;
    esac
}

TEST_PATHS=$(get_test_paths "$DOMAIN")

mkdir -p "$OUTPUT_DIR"

echo "=== Verifying edits for domain: $DOMAIN ==="
echo "Base branch: $BASE_BRANCH"
echo "Output dir: $OUTPUT_DIR"
echo "Test paths: $TEST_PATHS"

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

# Tests (path-scoped across all auth-related test directories)
echo "--- Tests (path-scoped) ---"
TEST_FAILED=0
for test_path in $TEST_PATHS; do
    if [ -d "$test_path" ]; then
        echo "  Running: $test_path"
        if ! make test ARGS="$test_path" >> "$OUTPUT_DIR/tests.txt" 2>&1; then
            TEST_FAILED=1
        fi
    else
        echo "  Skipping (not found): $test_path"
    fi
done

if [ "$TEST_FAILED" -eq 0 ]; then
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
