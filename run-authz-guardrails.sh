#!/usr/bin/env bash
# run-authz-guardrails.sh - Single entrypoint for AuthZ guardrails workflow
# Usage: ./run-authz-guardrails.sh [base_branch]
#
# Runs: preflight -> shellcheck -> pre-edit -> post-edit
# Prints evidence directory at the end
#
# Environment:
#   ALLOW_DIRTY=1  - Skip preflight check (use when working on real AuthZ changes)
#   BASE_BRANCH    - Base branch for comparison (default: develop)
#   NO_UNICODE=1   - Use ASCII output (for limited terminals)
#   LOG_RUNS=1     - Append run results to ~/authz-guardrails-runs.log
#
# Exit codes:
#   0 = PASS (all guardrails passed)
#   1 = FAIL (guardrails failed - lint/types/tests)
#   2 = TOOLING_ERROR (workflow issue - preflight, shellcheck, missing result)
#
# Cleanup old evidence (run manually):
#   find /tmp/claude-baseline -type d -mtime +7 -exec rm -rf {} + 2>/dev/null

set -euo pipefail

# Always run from repo root for consistency
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

SCRIPT_DIR="$REPO_ROOT/.claude/local"
BASE_BRANCH="${1:-${BASE_BRANCH:-develop}}"
CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo "detached")"

echo "============================================"
echo "AuthZ Guardrails Workflow"
echo "============================================"
echo "Repo root:   $REPO_ROOT"
echo "Base branch: $BASE_BRANCH"
echo "============================================"
echo ""

# Step 1: Preflight check (unless ALLOW_DIRTY=1)
if [[ "${ALLOW_DIRTY:-0}" == "1" ]]; then
    echo "[1/4] Preflight check SKIPPED (ALLOW_DIRTY=1)"
    echo "  WARNING: Running with dirty repo - ensure you know what you're doing"
    echo ""
    # Context header: show branch and dirty file count to catch human error
    DIRTY_COUNT=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    DIRTY_PREVIEW=$(git status --porcelain 2>/dev/null | head -5)
    echo "  Context:"
    echo "    Branch: $CURRENT_BRANCH"
    echo "    Dirty files: $DIRTY_COUNT"
    if [[ -n "$DIRTY_PREVIEW" ]]; then
        while IFS= read -r line; do
            printf '      %s\n' "$line"
        done <<< "$DIRTY_PREVIEW"
        if [[ "$DIRTY_COUNT" -gt 5 ]]; then
            echo "      ... and $((DIRTY_COUNT - 5)) more"
        fi
    fi
    echo ""
else
    echo "[1/4] Running preflight check..."
    if ! "$SCRIPT_DIR/hooks/preflight.sh"; then
        echo ""
        echo "Preflight FAILED - aborting (TOOLING_ERROR)"
        echo ""
        echo "To run anyway (e.g., when testing real AuthZ changes):"
        echo "  ALLOW_DIRTY=1 $0 $BASE_BRANCH"
        exit 2
    fi
fi

# Step 2: Shellcheck on hook scripts
echo "[2/4] Running shellcheck on hooks..."
SHELLCHECK_FAILED=0
for script in "$SCRIPT_DIR/hooks/"*.sh; do
    if [[ -f "$script" ]]; then
        echo "  Checking: $(basename "$script")"
        if ! shellcheck "$script" 2>&1 | head -20; then
            SHELLCHECK_FAILED=1
        fi
    fi
done

if [[ "$SHELLCHECK_FAILED" -eq 1 ]]; then
    echo ""
    echo "Shellcheck FAILED - fix issues before proceeding (TOOLING_ERROR)"
    exit 2
fi
echo "  Shellcheck: PASS"
echo ""

# Banner helpers (NO_UNICODE=1 for ASCII mode) - defined early for error messages
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

# Logging function (only logs if LOG_RUNS=1)
log_run() {
    local exit_code="$1"
    local result="$2"
    if [[ "${LOG_RUNS:-0}" == "1" ]]; then
        local log_file="${HOME}/authz-guardrails-runs.log"
        # Use ISO-8601 format compatible with both macOS and GNU date
        printf "%s\tbranch=%s\tbase=%s\texit=%s\tresult=%s\tevidence=%s\n" \
            "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$CURRENT_BRANCH" "$BASE_BRANCH" "$exit_code" "$result" "${POST_DIR:-none}" \
            >> "$log_file"
    fi
}

# Helper: Check that required make targets exist (classify missing as TOOLING_ERROR)
# Uses || true to prevent set -e from exiting before we can show the banner
require_make_target() {
    local target="$1"
    local make_exit
    make -n "$target" >/dev/null 2>&1 || make_exit=$?
    make_exit=${make_exit:-0}
    if [[ $make_exit -ne 0 ]]; then
        echo ""
        echo "$BANNER_LINE"
        echo "$SYM_UNKNOWN AuthZ Guardrails TOOLING_ERROR | Missing make target: $target"
        echo "$BANNER_LINE"
        log_run 2 "TOOLING_ERROR"
        exit 2
    fi
}

# Pre-check: Verify required make targets exist (fail fast if repo's Makefile changed)
echo "Checking required make targets..."
require_make_target check-python-lint-new-code
require_make_target check-python-types-new-code
require_make_target test
echo "  Make targets: OK"
echo ""

# Step 3: Run pre-edit baseline capture
echo "[3/4] Capturing pre-edit baseline..."
PRE_OUTPUT=$("$SCRIPT_DIR/hooks/pre-edit.sh" authz "$BASE_BRANCH" 2>&1) || true
echo "$PRE_OUTPUT"
# Parse: "Baseline captured to: /path" or "Output dir: /path"
PRE_DIR=$(echo "$PRE_OUTPUT" | grep -E "Baseline captured to:|Output dir:" | tail -1 | sed 's/.*: //')
echo ""

# Step 4: Run post-edit verification
echo "[4/4] Running post-edit verification..."
POST_OUTPUT=$("$SCRIPT_DIR/hooks/post-edit.sh" authz "$BASE_BRANCH" 2>&1) || true
echo "$POST_OUTPUT"
# Parse: "Output directory: /path" or "Output dir: /path"
POST_DIR=$(echo "$POST_OUTPUT" | grep -E "Output dir:|Output directory:" | tail -1 | sed 's/.*: //')
echo ""

# Summary
echo "============================================"
echo "Workflow Complete"
echo "============================================"
echo ""
echo "Evidence directories:"
if [[ -n "${PRE_DIR:-}" ]]; then
    echo "  Pre-edit:  $PRE_DIR"
else
    echo "  Pre-edit:  (not captured)"
fi
if [[ -n "${POST_DIR:-}" ]]; then
    echo "  Post-edit: $POST_DIR"
else
    echo "  Post-edit: (not captured)"
fi
echo ""

# Check result
# Find the most recent post-edit directory if POST_DIR wasn't captured
if [[ -z "${POST_DIR:-}" ]]; then
    # shellcheck disable=SC2012  # ls is fine here - dirs are timestamps (alphanumeric)
    POST_DIR=$(ls -td /tmp/claude-baseline/post/authz/* 2>/dev/null | head -1 || true)
fi

RESULT_FILE="${POST_DIR:-/tmp/claude-baseline/post/authz}/result.txt"
if [[ -f "$RESULT_FILE" ]]; then
    # Result file contains "RESULT: PASS" or "RESULT: FAIL"
    if grep -q "PASS" "$RESULT_FILE"; then
        echo "Result: PASS - All guardrails passed"
        echo ""
        echo "$BANNER_LINE"
        echo "$SYM_PASS AuthZ Guardrails PASS | $POST_DIR"
        echo "$BANNER_LINE"
        log_run 0 "PASS"
        exit 0
    else
        # Guardrails failed (lint/types/tests) - not a tooling failure
        echo "Result: FAIL - Guardrails failed (see evidence for details)"
        echo ""
        echo "$BANNER_LINE"
        echo "$SYM_FAIL AuthZ Guardrails FAIL | $POST_DIR"
        echo "$BANNER_LINE"
        log_run 1 "FAIL"
        exit 1
    fi
else
    # Tooling/workflow issue - couldn't even produce a result
    echo "Result: UNKNOWN - Workflow error (no result file at $RESULT_FILE)"
    echo ""
    echo "$BANNER_LINE"
    echo "$SYM_UNKNOWN AuthZ Guardrails TOOLING_ERROR | No result file"
    echo "$BANNER_LINE"
    echo "Check the post-edit output above for errors."
    log_run 2 "TOOLING_ERROR"
    exit 2
fi
