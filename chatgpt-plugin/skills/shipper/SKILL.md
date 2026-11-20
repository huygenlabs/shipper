---
name: shipper-app-store-connect
description: Validate local iOS and macOS packages and upload them to App Store Connect with Shipper's local MCP server.
---

# Shipper for App Store Connect

Use this plugin only with local `.ipa` and `.pkg` files on the user's Mac.

1. Call `list_teams` before acting and identify the intended team by its Team ID and name.
2. Call `validate_build` first when the user asks to validate or inspect a build. Report Apple's findings and do not upload.
3. For an upload request, confirm the exact file and team with the user before calling `upload_build`. Uploads cannot be recalled from App Store Connect.
4. `upload_build` performs Apple's validation again immediately before delivering. Report validation or upload errors without claiming success.
5. If the server says no Apple Account is configured, tell the user to run the bundled `shipper-mcp --setup` command in Terminal. Never ask them to paste an Apple password, app-specific password, or `.p8` key into chat.

The server runs locally and accesses only the path explicitly supplied for the current request. Apple app-specific passwords are entered through a hidden Terminal prompt and stored in the macOS login Keychain.
