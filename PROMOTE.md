# Promotion Checklist - AuthZ Guardrails

Criteria that must be met before moving this tooling from `.claude/local/` to shared `.claude/shared/` (team feature).

## Pre-Promotion Requirements

### Stability (must all be true)

- [ ] Ran successfully on 10+ real AuthZ changes without false positives
- [ ] No silent fallbacks - fails fast on error conditions
- [ ] Base branch resolution is deterministic (no HEAD~N fallbacks)
- [ ] Evidence artifacts are complete and parseable

### Documentation (must all exist)

- [ ] Clear usage instructions (one command to run)
- [ ] STOP conditions documented with remediation steps
- [ ] Evidence artifact locations documented
- [ ] Integration point with `/git-push` documented

### Testing (must all pass)

- [ ] Shellcheck passes on all scripts
- [ ] Scripts work on both macOS and Linux (bash 3.2+ compatible)
- [ ] Works with both local and CI environments
- [ ] Handles edge cases: no authz changes, fresh clone, detached HEAD

### Integration (must be reviewed)

- [ ] `/git-push` integration tested with real workflow
- [ ] Non-skippable behavior confirmed (no `--skip-authz` flag)
- [ ] Failure messaging is clear and actionable
- [ ] At least one team member has reviewed the approach

## Promotion Steps

When all boxes are checked:

1. **Copy to shared location**
   ```bash
   mkdir -p .claude/shared/authz-guardrails
   cp -r .claude/local/hooks .claude/shared/authz-guardrails/
   cp .claude/local/authz-guardrails/SKILL.md .claude/shared/authz-guardrails/
   ```

2. **Remove from global ignore**
   ```bash
   # Edit ~/.config/git/ignore and remove .claude/local/ line
   # Or keep local/ ignored and only share the shared/ directory
   ```

3. **Update /git-push command**
   - Modify `.claude/commands/git-push.md` to reference shared location
   - Add Step 2.5: AuthZ Guardrails Check

4. **Open PR**
   - Title: "Add AuthZ guardrails to /git-push workflow"
   - Include: skill contract, hooks, updated git-push.md
   - Reviewers: Sam, Jonathan, or another auth-familiar engineer

5. **Socialize**
   - Demo in team standup or async video
   - Document in internal wiki/runbook
   - Add to onboarding for AuthZ work

## Rollback Plan

If issues arise after promotion:

1. Revert the PR
2. Re-add `.claude/shared/authz-guardrails/` to `.gitignore`
3. Document what went wrong in `.claude/local/LEARNINGS.md`
4. Fix and re-attempt promotion

## Success Metrics

After promotion, track:

- Number of AuthZ changes that pass guardrails on first try
- Number of STOP events (expected to decrease over time)
- Time saved vs. manual review
- Bugs caught before merge
