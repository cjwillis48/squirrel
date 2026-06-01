---
description: Rebuild this project's nest index from the current nest files.
---

The user invoked `/refresh-nest`. Their goal: regenerate this project's `.claude/nest/INDEX.md` so it reflects the current state of the nest files — picking up any hand edits to a file's title, first bullet, `summary:`, `priority:`, or `status:` that haven't been synced yet.

Call the `refresh_nest_index` MCP tool. If the cwd is a registered project it resolves automatically; if the tool reports the cwd is too generic, ask the user once which project they mean and pass it explicitly.

After it runs, acknowledge in **one short sentence** — confirm the index was rebuilt. Don't list the entries back, don't summarize the nest, don't propose follow-ups. This is a maintenance action; the user wants it done and to move on.

If the tool reports an error, relay it in one line.
