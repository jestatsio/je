# Studio client plugin

The je plugin contains three shared skills for connection setup, status checks, and personal memory. It has no hooks, MCP server definitions, embedded credentials, or automatic model switching. Install it through `je setup` after reviewing the confirmation. Start a new client session to use the skills.

The public repository supplies two catalogs for the same plugin directory. Codex reads `.agents/plugins/marketplace.json` and the portable root `plugin.json`. Claude Code reads `.claude-plugin/marketplace.json` and `.claude-plugin/plugin.json` inside the plugin. The skill content is shared.

The implementation follows the official [OpenAI plugin packaging guide](https://developers.openai.com/plugins/build/plugins), [Codex plugin commands](https://learn.chatgpt.com/docs/developer-commands#codex-plugin), [Claude plugin installation guide](https://code.claude.com/docs/en/discover-plugins), and [Claude manifest reference](https://code.claude.com/docs/en/plugins/manifest-reference).

Use `je setup --dry-run` to inspect integrations without changes. Use `je setup --client codex --remove` or `je setup --client claude --remove` to remove a user installation after confirmation. Removal leaves the marketplace registered. Existing model and memory profiles remain separate from plugin installation.
