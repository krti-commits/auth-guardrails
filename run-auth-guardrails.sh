#!/usr/bin/env bash
# run-auth-guardrails.sh - Profile-based auth guardrails workflow
# Usage: ./run-auth-guardrails.sh [profile] [base_branch]
#
# Profiles:
#   authz-core     - Authorization decision engine (kamiwaza/services/authz/)
#   authn-gateway  - Authentication gateway (kamiwaza/services/auth/, policy files)
#   enforce        - Guard enforcement callers (ingestion, retrieval, models, catalog)
#   all            - Run all profiles (noisy, use sparingly)
#
# Environment:
#   ALLOW_DIRTY=1  - Skip preflight check
#   BASE_BRANCH    - Base branch for comparison (default: develop)
#   NO_UNICODE=1   - Use ASCII output
#   LOG_RUNS=1     - Append to ~/auth-guardrails-runs.log
#
# Exit codes:
#   0 = PASS, 1 = FAIL, 2 = TOOLING_ERROR

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

SCRIPT_DIR="$REPO_ROOT/.claude/local"
PROFILE="${1:-authz-core}"
BASE_BRANCH="${2:-${BASE_BRANCH:-develop}}"
CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo "detached")"

# Profile definitions
# shellcheck disable=SC2034  # SOURCE_PATHS used for documentation/future file-change detection
get_profile_config() {
    local profile="$1"
    case "$profile" in
        authz-core)
            TEST_PATHS="tests/unit/services/authz/"
            SOURCE_PATHS="kamiwaza/services/authz/"
            POLICY_FILE=""
            DESCRIPTION="Authorization decision engine (SpiceDB, guards, tenants)"
            ;;
        authn-gateway)
            TEST_PATHS="tests/unit/services/auth/"
            SOURCE_PATHS="kamiwaza/services/auth/"
            POLICY_FILE="config/auth_gateway_policy.yaml"
            DESCRIPTION="Authentication gateway (Keycloak, OIDC, SAML, JWT, RBAC policy)"
            ;;
        enforce)
            # Services that CALL auth guards (not the guards themselves)
            TEST_PATHS="tests/unit/services/ingestion/ tests/unit/services/retrieval/ tests/unit/services/catalog/ tests/unit/services/models/"
            SOURCE_PATHS="kamiwaza/services/ingestion/ kamiwaza/services/retrieval/ kamiwaza/services/catalog/ kamiwaza/services/models/"
            POLICY_FILE=""
            DESCRIPTION="Guard enforcement callers (ingestion, retrieval, catalog, models)"
            ;;
        all)
            TEST_PATHS="tests/unit/services/auth/ tests/unit/services/authz/ tests/unit/services/ingestion/ tests/unit/services/retrieval/ tests/unit/services/catalog/ tests/unit/services/models/"
            SOURCE_PATHS="kamiwaza/services/auth/ kamiwaza/services/authz/"
            POLICY_FILE="config/auth_gateway_policy.yaml"
            DESCRIPTION="Full auth surface (noisy - use specific profiles when possible)"
            ;;
        *)
            echo "Unknown profile: $profile"
            echo "Available: authz-core, authn-gateway, enforce, all"
            exit 2
            ;;
    esac
}

get_profile_config "$PROFILE"

# Banner
echo "============================================"
echo "Auth Guardrails Workflow"
echo "============================================"
echo "Profile:     $PROFILE"
echo "Description: $DESCRIPTION"
echo "Base branch: $BASE_BRANCH"
echo "Test paths:  $TEST_PATHS"
if [[ -n "$POLICY_FILE" ]]; then
    echo "Policy file: $POLICY_FILE"
fi
echo "============================================"
echo ""

# Unicode/ASCII mode
if [[ "${NO_UNICODE:-0}" == "1" ]]; then
    BANNER_LINE="--------------------------------------------"
    SYM_PASS="[PASS]"
    SYM_FAIL="[FAIL]"
    SYM_UNKNOWN="[????]"
else
    BANNER_LINE="────────────────────────────────────────────"
    SYM_PASS="✓"
    SYM_FAIL="✗"
    SYM_UNKNOWN="?"
fi

# Logging
log_run() {
    local exit_code="$1"
    local result="$2"
    if [[ "${LOG_RUNS:-0}" == "1" ]]; then
        local log_file="${HOME}/auth-guardrails-runs.log"
        printf "%s\tprofile=%s\tbranch=%s\tbase=%s\texit=%s\tresult=%s\tevidence=%s\n" \
            "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$PROFILE" "$CURRENT_BRANCH" "$BASE_BRANCH" "$exit_code" "$result" "${OUTPUT_DIR:-none}" \
            >> "$log_file"
    fi
}

# Make target check
require_make_target() {
    local target="$1"
    local make_exit
    make -n "$target" >/dev/null 2>&1 || make_exit=$?
    make_exit=${make_exit:-0}
    if [[ $make_exit -ne 0 ]]; then
        echo "$BANNER_LINE"
        echo "$SYM_UNKNOWN Auth Guardrails TOOLING_ERROR | Missing: $target"
        echo "$BANNER_LINE"
        log_run 2 "TOOLING_ERROR"
        exit 2
    fi
}

# Step 1: Preflight
if [[ "${ALLOW_DIRTY:-0}" == "1" ]]; then
    echo "[1/5] Preflight SKIPPED (ALLOW_DIRTY=1)"
    DIRTY_COUNT=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    echo "  Branch: $CURRENT_BRANCH | Dirty files: $DIRTY_COUNT"
    echo ""
else
    echo "[1/5] Running preflight check..."
    if ! "$SCRIPT_DIR/hooks/preflight.sh"; then
        echo "Preflight FAILED (TOOLING_ERROR)"
        echo "  Use ALLOW_DIRTY=1 to skip"
        exit 2
    fi
fi

# Step 2: Shellcheck
echo "[2/5] Running shellcheck..."
SHELLCHECK_FAILED=0
for script in "$SCRIPT_DIR/hooks/"*.sh; do
    if [[ -f "$script" ]]; then
        if ! shellcheck "$script" >/dev/null 2>&1; then
            echo "  FAIL: $(basename "$script")"
            SHELLCHECK_FAILED=1
        fi
    fi
done
if [[ "$SHELLCHECK_FAILED" -eq 1 ]]; then
    echo "Shellcheck FAILED (TOOLING_ERROR)"
    exit 2
fi
echo "  Shellcheck: PASS"
echo ""

# Step 3: Make targets
echo "[3/5] Checking make targets..."
require_make_target check-python-lint-new-code
require_make_target check-python-types-new-code
require_make_target test
echo "  Make targets: OK"
echo ""

# Setup output directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="/tmp/claude-baseline/post/${PROFILE}/${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

PASS=0
FAIL=0
FAILED_CHECKS=""

# Step 4: Quality checks
echo "[4/5] Running quality checks..."

# Lint
echo "  Lint..."
if BRANCH="$BASE_BRANCH" make check-python-lint-new-code > "$OUTPUT_DIR/lint.txt" 2>&1; then
    echo "    Lint: PASS"
    ((PASS++)) || true
else
    echo "    Lint: FAIL"
    FAILED_CHECKS="${FAILED_CHECKS} lint"
    ((FAIL++)) || true
fi

# Types
echo "  Types..."
if BRANCH="$BASE_BRANCH" make check-python-types-new-code > "$OUTPUT_DIR/types.txt" 2>&1; then
    echo "    Types: PASS"
    ((PASS++)) || true
else
    echo "    Types: FAIL"
    FAILED_CHECKS="${FAILED_CHECKS} types"
    ((FAIL++)) || true
fi

# Policy file validation (authn-gateway profile)
if [[ -n "$POLICY_FILE" && -f "$POLICY_FILE" ]]; then
    echo "  Policy file..."
    # Validate YAML syntax and required keys
    if python3 -c "
import yaml
import sys
try:
    with open('$POLICY_FILE') as f:
        policy = yaml.safe_load(f)
    # Check required structure
    if not isinstance(policy, dict):
        print('Policy must be a dict', file=sys.stderr)
        sys.exit(1)
    if 'version' not in policy and 'roles' not in policy and 'rules' not in policy:
        print('Policy missing expected keys (version, roles, or rules)', file=sys.stderr)
        sys.exit(1)
    print('Policy structure: OK')
except Exception as e:
    print(f'Policy validation failed: {e}', file=sys.stderr)
    sys.exit(1)
" > "$OUTPUT_DIR/policy.txt" 2>&1; then
        echo "    Policy: PASS"
        ((PASS++)) || true
    else
        echo "    Policy: FAIL"
        FAILED_CHECKS="${FAILED_CHECKS} policy"
        ((FAIL++)) || true
    fi
fi
echo ""

# Step 5: Tests (profile-scoped)
echo "[5/5] Running tests..."
TEST_FAILED=0
for test_path in $TEST_PATHS; do
    if [[ -d "$test_path" ]]; then
        echo "  $test_path"
        if ! make test ARGS="$test_path" >> "$OUTPUT_DIR/tests.txt" 2>&1; then
            TEST_FAILED=1
        fi
    fi
done

if [[ "$TEST_FAILED" -eq 0 ]]; then
    echo "    Tests: PASS"
    ((PASS++)) || true
else
    echo "    Tests: FAIL"
    FAILED_CHECKS="${FAILED_CHECKS} tests"
    ((FAIL++)) || true
fi
echo ""

# Summary
echo "============================================"
echo "Summary: $PASS passed, $FAIL failed"
echo "Evidence: $OUTPUT_DIR"
echo "============================================"

if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "Failed checks:$FAILED_CHECKS"
    echo ""
    echo "RESULT: FAIL" | tee "$OUTPUT_DIR/result.txt"
    echo ""
    echo "$BANNER_LINE"
    echo "$SYM_FAIL Auth Guardrails [$PROFILE] FAIL"
    echo "$BANNER_LINE"
    log_run 1 "FAIL"
    exit 1
else
    echo "RESULT: PASS" | tee "$OUTPUT_DIR/result.txt"
    echo ""
    echo "$BANNER_LINE"
    echo "$SYM_PASS Auth Guardrails [$PROFILE] PASS"
    echo "$BANNER_LINE"
    log_run 0 "PASS"
    exit 0
fi
