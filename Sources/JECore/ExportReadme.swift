import Foundation

/// The review README written into every desktop export bundle. The Codex
/// section has one variant for profiles without a catalog binding and one
/// for profiles with a saved binding; the rest is shared.
enum ExportReadme {
    static func text(hasCatalogBinding: Bool) -> String {
        prefix + "\n"
            + (hasCatalogBinding ? boundCatalogSection : missingCatalogSection) + "\n"
            + suffix + "\n"
    }

    private static let prefix = """
# Review these connection fragments before applying them

These files have not activated or tested a desktop connection. They contain no
gateway credentials. The apps retrieve the selected profile's token by running
the configured absolute executable. Codex and Claude Desktop use argument arrays;
Claude Code uses a quoted POSIX shell command. The helper must print
only the token and exit successfully; never paste its output into these files.
Keep the executable and private profile directory available on this computer.

## Codex app and editor

Back up the existing Codex config before making any changes. Review
`codex.config.toml` as a merge fragment for the config used by your app or editor.
Merge root keys at the document root and merge the named provider table; do not
append this whole fragment beneath an existing TOML table or replace the entire
config. Resolve any existing provider with this name deliberately. Command
authentication cannot be combined with an `env_key` or a static bearer token in
that provider. Keep other providers, approvals, tools, hooks, and instructions.

"""

    private static let missingCatalogSection = """
The selected alias still needs a model catalog compatible with the exact Codex
version used by the app or extension. No catalog is exported: the saved profile
does not establish the model's instructions, tool formats, or other capabilities.
Do not copy another model's metadata or treat the configured context limit as
proof of compatibility. Supply and qualify the matching catalog before relying
on this connection. Shared app-server behavior also needs a runtime test.
"""

    private static let boundCatalogSection = """
This profile includes a saved catalog binding. The manifest records its
source path, SHA-256 digest, and required Codex version. Export rechecked the
source bytes, selected model, and context limit. The bundle also includes an
exact copy in `codex.catalog.json` for review and preservation.

The configuration fragment references the original absolute source path. If you
use the preserved copy instead, replace that value with the copy's absolute path
before merging. Static desktop configuration does not enforce the required
version or digest on later launches. Verify both before activating and after any
upgrade or catalog edit. Only `je connect codex` enforces the saved binding at
launch and supplies a private snapshot for that session. This export has not
qualified the model or tested the desktop/editor runtime.
"""

    private static let suffix = """

## Claude Desktop

Review `claude-desktop.json` against Claude Desktop's third-party inference
configuration. It is not the MCP configuration file and is not a Claude Code
CLI settings file. Back up the current third-party inference configuration and
merge the reviewed values through the documented configuration workflow.
Credential helper arguments require Claude Desktop 2.110.0 or later.

The file selects exactly the saved model alias. It makes no Claude-family
capability claims, and the local model's context-window binding remains
unverified. Desktop's native action approvals also need qualification; Auto mode
can require a separate safety-classifier model route. Do not disable approvals
to make an incomplete route appear usable. This export does not establish
vendor support or successful tool use with a non-Claude model.

## Claude Code in VS Code

Back up the Claude Code and VS Code settings before applying these fragments.
Review `claude-code.settings.json` as a merge fragment for the normal
`~/.claude/settings.json` in the account where the extension runs. With Remote
SSH, that is the remote account. Its `apiKeyHelper` is quoted for a POSIX shell;
do not apply this command unchanged to a Windows shell. The helper executable
and saved profile must exist in that same environment.

Merge the `env` entries individually and retain unrelated settings, hooks, tools,
instructions, and native approvals. Resolve existing API-key, bearer-token,
OAuth-token, or alternate-provider settings before activation; those can override
the helper or endpoint. Do not paste credentials into either fragment.

Review `claude-code.vscode-settings.json` for the applicable VS Code user or
remote settings. It selects external authentication and the native Manual
approval mode (`default`). It does not enable permission bypass or replace a
configured permission policy. Disabling the login prompt does not authenticate
the connection.

All model roles use the selected alias, including auxiliary and subagent calls.
These mappings and the requested context limit do not establish model capability
or runtime context handling. The editor's prelaunch authentication remains unverified,
as do native approvals and task execution. Before relying on this connection,
check the extension's bundled CLI authentication status for the helper, then
qualify the actual editor connection and gateway attribution. CLI helper behavior
alone does not verify the editor connection.

## Reversal

To undo a later activation, restore the backed-up config and restart the affected
app or extension. Retain other changes made since that backup when restoring.
Deleting this export directory alone does not undo settings applied elsewhere.

## Configuration references

- https://learn.chatgpt.com/docs/enterprise/roll-out-a-gateway
- https://learn.chatgpt.com/docs/model-catalogs
- https://claude.com/docs/third-party/claude-desktop/configuration
- https://claude.com/docs/third-party/claude-desktop/credential-helper
- https://code.claude.com/docs/en/llm-gateway-connect
- https://code.claude.com/docs/en/settings-reference#apikeyhelper
- https://code.claude.com/docs/en/model-config
- https://code.claude.com/docs/en/vs-code
"""
}
