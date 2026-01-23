#!/usr/bin/env bash
# Pre-edit hook: Capture baseline state before modifications
# Usage: ./pre-edit.sh [domain] [base-branch]
# Example: ./pre-edit.sh auth develop
# Env: BRANCH=develop ./pre-edit.sh auth
#
# Domains:
#   auth    - Full auth surface (auth + authz services, guards, dependencies)
#   authz   - Authorization only (legacy, maps to auth)

set -euo pipefail

DOMAIN="${1:-auth}"
BASE_BRANCH="${2:-${BRANCH:-develop}}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="/tmp/claude-baseline/pre/${DOMAIN}/${TIMESTAMP}"

# Map domain to test paths
# "auth" covers the full authentication + authorization surface
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

# Map domain to source paths (for reference)
get_source_paths() {
    local domain="$1"
    case "$domain" in
        auth|authz)
            echo "kamiwaza/services/auth/ kamiwaza/services/authz/ kamiwaza/dependencies/auth.py"
            ;;
        *)
            echo "kamiwaza/services/${domain}/"
            ;;
    esac
}

TEST_PATHS=$(get_test_paths "$DOMAIN")
SOURCE_PATHS=$(get_source_paths "$DOMAIN")

mkdir -p "$OUTPUT_DIR"

echo "=== Capturing baseline for domain: $DOMAIN ==="
echo "Base branch: $BASE_BRANCH"
echo "Timestamp: $TIMESTAMP"
echo "Output dir: $OUTPUT_DIR"
echo "Test paths: $TEST_PATHS"
echo "Source paths: $SOURCE_PATHS"

# Capture git state
echo "--- Git Status ---"
git diff --stat > "$OUTPUT_DIR/diff.txt" 2>&1 || true
git status --short > "$OUTPUT_DIR/status.txt" 2>&1 || true

# Run path-scoped tests (always deterministic, doesn't depend on branch diff)
echo "--- Running Tests (path-scoped) ---"
TEST_RESULT="PASS"
TEST_OUTPUT=""

for test_path in $TEST_PATHS; do
    if [ -d "$test_path" ]; then
        echo "  Running: $test_path"
        if ! make test ARGS="$test_path" >> "$OUTPUT_DIR/tests.txt" 2>&1; then
            TEST_RESULT="FAIL"
        fi
    else
        echo "  Skipping (not found): $test_path"
    fi
done

if [ "$TEST_RESULT" = "PASS" ]; then
    echo "Tests: PASS"
else
    echo "Tests: FAIL (or some paths not found)"
fi
echo "$TEST_RESULT" > "$OUTPUT_DIR/tests_result.txt"

echo ""
echo "Baseline captured to: $OUTPUT_DIR"
echo "Files created:"
ls -la "$OUTPUT_DIR"/*.txt 2>/dev/null || echo "  (none)"
