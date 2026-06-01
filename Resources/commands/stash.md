---
description: Stash an idea into the Squirrel forest without breaking the conversation flow.
---

The user invoked `/stash` to capture an idea. Their input is:

$ARGUMENTS

Call the `stash_idea` MCP tool with `text` set to the input above. If the current cwd is a registered project, let `project` and `nest` default (they'll auto-resolve and auto-nest).

After the tool call, acknowledge with **one short sentence** — confirm the stash and the title that was assigned. Don't elaborate, don't propose follow-ups, don't ask if they want to triage. The user typed `/stash` precisely because they didn't want to interrupt what they were doing; respect that and let them get back to it.

If `$ARGUMENTS` is empty, ask once for the idea text in a single sentence, no preamble.
