---
name: memory
description: Help users inspect and attach their separate Studio memory connection, and use an attached memory service for explicitly requested facts.
---

Use `je memory list` and `je memory show NAME` to inspect saved memory connection metadata. Use `je memory check NAME` to check advertised tools. This check does not read memories or prove that tool execution will succeed.

For a new connection, have the user run `je memory add NAME --endpoint URL` in their own terminal with the operator-provided MCP address. The command prompts privately for a separate memory token. Never ask for that token in chat, put it in command arguments, or open the saved connection file.

Memory is attached explicitly with `je connect claude --profile MODEL_PROFILE --memory-profile MEMORY_PROFILE`, or the corresponding Codex command with a qualified Codex profile. Explain this command without starting a nested client unless the user asks. Installing this plugin alone does not attach memory.

When the current session already has Studio memory tools, use those tools for the user's requested search, save, correction, or deletion. Confirm destructive choices when their scope is unclear. Never store credentials. Do not claim automatic saving or successful retention without a tool result. Explain that deleted records leave recall immediately and remain restorable in trash for 30 days.
