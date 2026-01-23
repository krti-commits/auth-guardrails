---
name: authz-guardrails
description: Validate and enforce D120 AuthZ invariants in code changes. Check ingress headers, service-layer guards, route posture, and RequesterContext compliance.
allowed-tools: [Bash, Read, Grep, Glob, Edit]
---

# AuthZ Guardrails Skill

Enforce D120 authorization contract invariants during code changes.

## (A) Scope

```yaml
scope:
  paths:
    read:
      - "kamiwaza/services/authz/**"
      - "kamiwaza/services/auth/**"
      - "kamiwaza/dependencies/auth.py"
      - "kamiwaza/main.py"
      - "tests/unit/services/authz/**"
      - "docs-internal/security/**"
    write:
      - "kamiwaza/services/authz/**"
      - "tests/unit/services/authz/**"
    forbidden:
      - ".env*"
      - "alembic/versions/**"
      - "kamiwaza/deployment/**"
      - "runtime/**"

  tools:
    allowed: [Read, Grep, Glob, Edit, Write, Bash]
    bash_allowlist:
      - "make test ARGS=tests/unit/services/authz/"
      - "make check-python-lint-new-code"
      - "make check-python-types-new-code"
      - "git diff --stat"
      - "git status"
    bash_denylist:
      - "git push"
      - "git commit"
      - "rm -rf"
      - "docker"
      - "make start-*"
      - "make stop-*"

  systems:
    - local filesystem
```

---

## (B) Pre-Checks

Before ANY edit, capture baseline:

```bash
git diff --stat
make test ARGS=tests/unit/services/authz/ 2>&1 | tee /tmp/baseline_tests.txt
```

After EVERY edit, verify:

```bash
make check-python-lint-new-code
make check-python-types-new-code
make test ARGS=tests/unit/services/authz/
```

---

## (C) Evidence Format

```markdown
## Execution Evidence

**Goal:** {task}
**Outcome:** {success | partial | blocked | failed}

### D120 Invariants Checked
- [ ] I1: Bounded discovery (pagination enforced)
- [ ] I2: Plan-manifest-confirm-execute (explicit confirmation)
- [ ] I3: Server-side enforcement (UI guides, server enforces)
- [ ] I4: Explicit persistence contract
- [ ] I5: Minimal auth adjacency (scoped discovery)

### Commands Run
| Command | Exit | Duration |
|---------|------|----------|

### Files Modified
| Path | Op | +/- |
|------|-----|-----|

### Verification
- [ ] Lint: PASS/FAIL
- [ ] Types: PASS/FAIL
- [ ] Tests: n/n PASS/FAIL
```

---

## (D) Stop Conditions

| Condition | Trigger | Action |
|-----------|---------|--------|
| Scope violation | Edit outside authz paths | STOP, request approval |
| Test regression | Test that passed now fails | STOP, show diff |
| Type errors up | New type errors introduced | STOP, show new errors |
| Missing guard | Mutation without service-layer guard | STOP, flag violation |
| Unbounded list | List endpoint without pagination | STOP, require limit |
| Breaking API | Public endpoint signature changed | STOP, confirm intent |

---

## When to Use

- Adding or modifying authentication/authorization code
- Implementing RequesterContext in endpoints
- Adding new protected routes
- Reviewing PRs touching authz paths
- Validating D120 compliance

## D120 Contract (TL;DR)

### 5 Non-Negotiable Invariants

| # | Invariant | Enforcement |
|---|-----------|-------------|
| I1 | Bounded discovery | Search with pagination, never unlimited lists |
| I2 | Plan-manifest-confirm | Explicit confirmation before destructive ops |
| I3 | Server-side enforcement | UI guides user, server enforces rules |
| I4 | Explicit persistence | Clear contract for data lifecycle |
| I5 | Minimal auth adjacency | Scoped discovery, explicit delegation |

### Key Patterns

**RequesterContext Usage:**
```python
from kamiwaza.services.authz.requester_context import (
    RequesterContext,
    get_requester_context,      # Optional auth (public endpoints)
    require_requester_context,  # Required auth (protected endpoints)
)

@router.get("/resource")
async def get_resource(context: RequesterContext = Depends(get_requester_context)):
    # context.authenticated: bool
    # context.user_id, context.roles, context.tenant_id available
```

**Service-Layer Guard (fail-closed):**
```python
async def delete_resource(id: UUID, context: RequesterContext = Depends(require_requester_context)):
    if not can_delete(context, id):
        raise HTTPException(403, "Forbidden")
```

## Common Operations

### Add RequesterContext to endpoint
1. Import `RequesterContext` and `require_requester_context`
2. Add dependency: `context: RequesterContext = Depends(require_requester_context)`
3. Use `context.requester_urn` for audit logging
4. Use `context.user_id` for ownership checks

### Validate D120 compliance
1. Check all mutations have service-layer guard
2. Verify list endpoints have pagination
3. Confirm destructive ops require confirmation

## References

- `docs-internal/security/api-authorization-reference.md`
- `kamiwaza/services/authz/requester_context.py`
