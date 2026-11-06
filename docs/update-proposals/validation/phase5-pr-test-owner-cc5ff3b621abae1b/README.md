# Phase 5.2 PR Validation Fixture

> **TEST ONLY — PHASE 5.2 PR VALIDATION**

This file exists solely to validate the Phase 5.2 pull-request
workflow (branch creation, PR creation, idempotent reruns).

- **fixture id**: `owner-cc5ff3b621abae1b`
- **branch**: `validation/phase5-pr-test-owner-cc5ff3b621abae1b`
- **payload**: documentation only — no PKGBUILD, no package
  sources, no release assets, no production changes.
- **do not merge**; merging publishes nothing.

## Content digest (fixture identity)

```
packages_checked=55
decision_count=10
update_count=0
```

The branch suffix is a SHA-256 digest of the canonical fixture
content (sorted package/state/version tuples). Identical content
always yields the same branch and PR; changed content yields a new
one.
