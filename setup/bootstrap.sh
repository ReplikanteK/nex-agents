#!/usr/bin/env bash
set -uo pipefail

# === Agent3 Bootstrap ===
# Ejecutar UNA VEZ tras crear el Codespace

echo "[nex3] Setting up Agent3 environment..."

# 1. Install opencode
if ! command -v opencode &>/dev/null; then
  echo "[nex3] Installing opencode..."
  curl -fsSL https://opencode.ai/install | bash
fi

export PATH="$HOME/.opencode/bin:$PATH"

# 2. Clone nex-agents
if [ ! -d "$HOME/nex-agents" ]; then
  gh repo clone ReplikanteK/nex-agents "$HOME/nex-agents" 2>/dev/null || true
fi

# 3. Create workspace structure
mkdir -p "$HOME/opencode-agent3"/{tasks,reports,fuzzing,scanner,memoria}

# 4. Config opencode.json
if [ -f "$HOME/nex-agents/.devcontainer/opencode.json" ]; then
  sed "s|\$HOME|$HOME|g" "$HOME/nex-agents/.devcontainer/opencode.json" > "$HOME/opencode-agent3/opencode.json"
fi

# 5. Git auth
gh auth setup-git 2>/dev/null || true

echo "[nex3] Setup complete."
echo "[nex3] Workspace: $HOME/opencode-agent3/"
