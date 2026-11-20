# Shipper for App Store Connect — ChatGPT Desktop

This plugin bundle runs a standalone local MCP server. It does not require the Shipper UI app.

## Setup

Requirements: ChatGPT Desktop on macOS 14 or later and Xcode with `xcrun altool` available.

1. Expand the plugin ZIP.
2. In Terminal, from the expanded folder, run `./mcp/shipper-mcp --setup` for each Apple Account. Enter an app-specific password at the hidden prompt. The helper validates the account and stores its password in the macOS login Keychain.
3. Add this folder to ChatGPT Desktop with Plugin Creator, preserving `.mcp.json`, `.codex-plugin/plugin.json`, and `skills/shipper/SKILL.md`.
4. In ChatGPT, call `list_teams`, `validate_build`, or `upload_build`. Confirm the intended team and file before upload.

Passwords are never MCP arguments. The server passes them to Apple's `altool` over standard input. This plugin does not maintain a visual upload queue or check Apple's post-upload processing state.

Each recipient needs their own Mac setup and Keychain credentials. Sharing or publishing the plugin does not distribute its local executable or credentials; it is Desktop-only.
