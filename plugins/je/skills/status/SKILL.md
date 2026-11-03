---
name: status
description: Check the installed je version, personal Studio connections, and Codex or Claude plugin setup without running model inference.
---

Start with `je --version` and `je profile list`. If the user names a saved connection, run `je doctor --profile NAME`. If they ask about native Ollama, inspect `je ollama profile list` and use `je ollama --profile NAME check`. Choose a profile with the user when several are available.

Use `je setup --dry-run` to inspect the Studio plugin integration in installed clients. Never print native plugin-list JSON or read client configuration files. Those can contain credentials for unrelated services.

Report missing tools, authentication failures, unavailable models, and installed integrations separately. A listed model or a working plugin does not prove coding quality, workspace health, or public access. Do not run `--probe`, launch a model, install tools, change plugins, or modify service settings as part of a status check.
