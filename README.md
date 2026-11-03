# je

Your tools. Your context. Your Studio.

The public client, native agent plugins, and documentation for J&E Studio.

## Install

On an Apple Silicon Mac with Homebrew installed, run the following command.

```sh
brew install jestatsio/tap/je
je setup
```

The client includes its runtime. You do not need Python or a source checkout. Setup detects installed Codex and Claude Code CLIs and asks before adding their native je plugins. Install the clients themselves separately.

[Read the documentation](https://jestatsio.github.io/je/) · [Download a release](https://github.com/jestatsio/je/releases) · [Report an issue](https://github.com/jestatsio/je/issues)

## Service access

Installing je does not grant access to a model or memory service. Get an endpoint, model name, and personal key from your Studio operator. The hosted Studio service is a private pilot.

The plugin provides instructions for using je. It does not contain credentials, switch models, attach memory, or install hooks. Connections remain explicit and each client keeps its approval controls.

## Update

```sh
brew update
brew upgrade jestatsio/tap/je
```

The agent plugins are separate installations. Use each client's native plugin manager to update them. Run `je setup --remove` to remove the je plugins with confirmation, then `brew uninstall je` to remove the client. Saved profiles remain on disk.

## What this repository contains

This repository holds the documentation, plugin manifests and skills, and downloadable client releases. The application source is maintained privately. Release archives include required third-party license notices and their SHA-256 checksums.

Built by [J&E Stats](https://jestats.io).
