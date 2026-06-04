---
captured: 2026-06-02T19:12:49Z
slug: sessionstart-hook-nudge-for
status: open   # one of: open | deferred | resolved | archived
# priority: P0   # optional, freeform — e.g. P0/P1/P2, high/medium/low, now/next/later
# summary:    # optional one-liner for INDEX.md; defaults to the first bullet below
---

# SessionStart hook nudge for unassigned squirrels count

- Add SessionStart hook (not UserPromptSubmit) to surface one-line unassigned-squirrel count at session open.
- Message format: `[🐿️] you have X unassigned squirrels in the forest — /review-squirrels to review`.
- Rename /scan-forest to /review-squirrels for co-location with where triage actually happens.
- Defer until after reconciliation work — this surfaces the untagged pile but doesn't shrink it.

## Raw capture

> Session-start "unassigned squirrels" nudge for Squirrel. On new Claude Code session only (SessionStart hook, NOT per-message), surface a one-line count: "[🐿️] you have X unassigned squirrels in the forest — /review-squirrels to review". Deliberate and co-located with where triage actually happens (in Claude Code, where /scan-forest lives), unlike the menu-bar badge which is on a separate surface. Bounded once-per-session, not pestery. Caveats to weigh before building: (1) reintroduces a hook after we just removed one — but a SessionStart hook is far safer than the old UserPromptSubmit one (no long tool-heavy turn to bury it, count-only so no per-item ack to drop, no nudged-state to burn); (2) small residual model-relay dependency at session start; (3) coarse cadence. Secondary to the reconciliation work — it surfaces the residual untagged pile, doesn't shrink it. /review-squirrels would just be /scan-forest renamed.
> 
> _Captured 2026-06-02T19:12:49Z_

## Notes

<!-- project-local notes accumulate here as you investigate -->
