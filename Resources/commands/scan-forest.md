---
description: Show untagged forest entries and triage which belong to this project.
---

The user invoked `/scan-forest`. Their goal: see what's currently untagged in their forest and decide what (if anything) belongs to the project they're working in.

Call the `untagged_ideas` MCP tool (no arguments needed — defaults to limit 30, most-recent-first). Present the result as a NUMBERED list (1, 2, 3…) using natural conversational language — never name MCP tools out loud. Each item should show:

- The title
- The timestamp in backticks (so you can map user replies back to entries)
- 1–2 bullet summary if the bullets add information beyond the title; skip bullets when the title is self-explanatory

After the list, ask which (if any) should go in this project's nest. The user replies by number — e.g. "1 and 3" / "just 2" / "none of those" / "all but the second one." Map their reply to the timestamps and call `nest_idea` per chosen item.

If they reply "none" or skip everything, just acknowledge in one line and stop — items not chosen stay in the forest untouched. No rejection bookkeeping, no follow-up. They'll appear in future `/scan-forest` invocations; that's fine.

If `untagged_ideas` returns "No untagged ideas — every entry already carries a project tag," tell the user that in one sentence and stop.
