# Studio for Codex and Claude Code

Use Studio's connection, status, and memory skills from your familiar coding client. The plugin contains instructions only. It does not change your model, approval settings, or memory connections.

Run `je setup` to detect installed clients and confirm each integration. Preview with `je setup --dry-run`. Start a new client session after installation.

You can also install with the native plugin manager:

```sh
codex plugin marketplace add jestatsio/je
codex plugin add je@jestudio
```

```sh
claude plugin marketplace add jestatsio/je
claude plugin install je@jestudio --scope user
```

Remove the integration with `je setup --client codex --remove` or `je setup --client claude --remove`. The marketplace remains registered, and your saved Studio connections remain available.

See the [Studio documentation](https://jestatsio.github.io/je/) for installation and connection setup.
