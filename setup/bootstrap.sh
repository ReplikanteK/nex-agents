#!/usr/bin/env bash
set -uo pipefail

# === Agent3 Bootstrap ===
# Ejecutar UNA VEZ tras crear el Codespace

echo "[nex3] Setting up Agent3 environment..."

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# 1. Install gh CLI
if ! command -v gh &>/dev/null; then
  echo "[nex3] Installing gh CLI..."
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg 2>/dev/null | $SUDO dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | $SUDO tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  $SUDO apt-get update -qq 2>/dev/null && $SUDO apt-get install gh -y -qq 2>&1 | tail -3
fi

# 2. Install opencode
if ! command -v opencode &>/dev/null; then
  echo "[nex3] Installing opencode..."
  curl -fsSL https://opencode.ai/install | bash
fi

export PATH="$HOME/.opencode/bin:$PATH"

# 3. Clone nex-agents
if [ ! -d "$HOME/nex-agents" ]; then
  gh repo clone ReplikanteK/nex-agents "$HOME/nex-agents" 2>/dev/null || true
fi

# 4. Create workspace structure
mkdir -p "$HOME/opencode-agent3"/{tasks,reports,fuzzing,scanner,memoria}

# 5. Config opencode.json
if [ -f "$HOME/nex-agents/.devcontainer/opencode.json" ]; then
  sed "s|\$HOME|$HOME|g" "$HOME/nex-agents/.devcontainer/opencode.json" > "$HOME/opencode-agent3/opencode.json"
fi

# 6. Git auth
gh auth setup-git 2>/dev/null || true

echo "[nex3] Setup complete."
echo "[nex3] Workspace: $HOME/opencode-agent3/"
