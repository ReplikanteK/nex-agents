#!/usr/bin/env bash
set -euo pipefail

# === Agent3 Bootstrap ===
# Ejecutar UNA VEZ tras crear el Codespace
# API keys se inyectan vía Codespace secrets (GITHUB_TOKEN, OPENCODE_API_KEY)

echo "[nex3] Setting up Agent3 environment..."

# 1. Install opencode CLI
if ! command -v opencode &>/dev/null; then
  echo "[nex3] Installing opencode..."
  npm install -g @anthropic-ai/cli-opencode
fi

# 2. Clone nex-agents (inbox/outbox) via gh auth
if [ ! -d "$HOME/nex-agents" ]; then
  gh repo clone ReplikanteK/nex-agents "$HOME/nex-agents"
fi

# 3. Clone agent1 memoria (read-only reference)
if [ ! -d "$HOME/opencode-agent/memoria" ]; then
  mkdir -p "$HOME/opencode-agent"
  gh repo clone ReplikanteK/nex-memoria "$HOME/opencode-agent/memoria"
fi

# 4. Create agent3 workspace
mkdir -p "$HOME/opencode-agent3"/{tasks,reports,fuzzing,scanner,memoria}

# 5. Copy opencode.json and inject HOME path
sed "s|\$HOME|$HOME|g" "$HOME/nex-agents/.devcontainer/opencode.json" > "$HOME/opencode-agent3/opencode.json"

# 6. Copy skills from shared repo if available
if [ -d "$HOME/opencode-agent/.opencode" ]; then
  cp -r "$HOME/opencode-agent/.opencode" "$HOME/opencode-agent3/.opencode"
fi

echo "[nex3] ✅ Setup complete. Agent3 ready."
echo "[nex3] Run: opencode --config $HOME/opencode-agent3/opencode.json"
