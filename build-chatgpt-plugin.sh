#!/bin/sh
# Builds the standalone, universal local MCP server and packages the ChatGPT Desktop plugin bundle.
set -eu
cd "$(dirname "$0")"

ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product shipper-mcp

STAGE="build.noindex/Shipper-ChatGPT-Plugin"
ZIP="Shipper-ChatGPT-Plugin.zip"
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE/mcp"
cp -R chatgpt-plugin/.codex-plugin "$STAGE/"
cp chatgpt-plugin/.mcp.json "$STAGE/"
cp -R chatgpt-plugin/skills "$STAGE/"
cp chatgpt-plugin/README.md "$STAGE/"
cp LICENSE "$STAGE/"
cp "$(swift build -c release $ARCHS --product shipper-mcp --show-bin-path)/shipper-mcp" "$STAGE/mcp/shipper-mcp"
chmod 755 "$STAGE/mcp/shipper-mcp"

# Preserve Unix permissions without adding macOS resource-fork sidecar files.
ditto -c -k --norsrc --keepParent "$STAGE" "$ZIP"
echo "Built $ZIP"
