#!/usr/bin/env bash
# Fix sharp native binaries in opencode-mem after Bun install
# Run once after installing the plugin, then restart OpenCode

set -euo pipefail

PLUGIN_DIR="$HOME/.cache/opencode/packages/opencode-mem@latest"

if [[ ! -d "$PLUGIN_DIR" ]]; then
  echo "Plugin not installed yet. Start OpenCode once to trigger installation."
  exit 1
fi

echo "Fixing sharp in main package..."
cd "$PLUGIN_DIR"
npm install --foreground-scripts sharp 2>&1 | tail -3

echo "Fixing sharp in @xenova/transformers..."
TRANSFORMERS_DIR="$PLUGIN_DIR/node_modules/@xenova/transformers"
cd "$TRANSFORMERS_DIR"
rm -rf node_modules/sharp node_modules/@img
npm install --foreground-scripts 2>&1 | tail -3

# Create symlink for sharp binary in transformers (npm doesn't do this correctly)
SHARP_BUILD="$TRANSFORMERS_DIR/node_modules/sharp/build/Release"
mkdir -p "$SHARP_BUILD"
rm -f "$SHARP_BUILD/sharp-linux-x64.node"
ln -s ../../../../../../@img/sharp-linux-x64/lib/sharp-linux-x64.node \
  "$SHARP_BUILD/sharp-linux-x64.node"

# Verify
if [[ -L "$SHARP_BUILD/sharp-linux-x64.node" ]] && [[ -f "$(readlink -f "$SHARP_BUILD/sharp-linux-x64.node")" ]]; then
  echo "Sharp binaries fixed. Restart OpenCode."
else
  echo "Fix failed. Check output above."
  exit 1
fi
