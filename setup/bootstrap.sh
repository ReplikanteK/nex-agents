#!/usr/bin/env bash
set -uo pipefail

# === Agent3 Bootstrap ===
# Ejecutar UNA VEZ tras crear el Codespace
# API keys via environment: GITHUB_TOKEN (built-in), OPENCODE_API_KEY (secret)

echo "[nex3] Setting up Agent3 environment..."

# 1. Install opencode CLI via official install script
if ! command -v opencode &>/dev/null; then
  echo "[nex3] Installing opencode..."
  curl -fsSL https://opencode.ai/install | bash
fi

# Ensure opencode is in PATH for the rest of the script
export PATH="$HOME/.opencode/bin:$PATH"

# 2. Clone nex-agents (inbox/outbox) via gh (ya autenticado en Codespace)
if [ ! -d "$HOME/nex-agents" ]; then
  gh repo clone ReplikanteK/nex-agents "$HOME/nex-agents" 2>/dev/null || {
    echo "[nex3] WARN: No se pudo clonar nex-agents, continuando..."
  }
fi

# 3. Intentar clone de nex-memoria (read-only, puede fallar si es privado)
if [ ! -d "$HOME/opencode-agent/memoria" ]; then
  mkdir -p "$HOME/opencode-agent"
  gh repo clone ReplikanteK/nex-memoria "$HOME/opencode-agent/memoria" 2>/dev/null || {
    echo "[nex3] WARN: nex-memoria no accesible (privado), skills no disponibles"
  }
fi

# 4. Create agent3 workspace
mkdir -p "$HOME/opencode-agent3"/{tasks,reports,fuzzing,scanner,memoria}

# 5. Copy opencode.json template with dynamic HOME path
if [ -f "$HOME/nex-agents/.devcontainer/opencode.json" ]; then
  sed "s|\$HOME|$HOME|g" "$HOME/nex-agents/.devcontainer/opencode.json" > "$HOME/opencode-agent3/opencode.json"
fi

# 6. Configure git auth via gh
gh auth setup-git 2>/dev/null || true

# 7. Add OPENCODE_API_KEY to bashrc for persistence
if ! grep -q "OPENCODE_API_KEY" "$HOME/.bashrc" 2>/dev/null; then
  echo 'export OPENCODE_API_KEY="${OPENCODE_API_KEY:-}"' >> "$HOME/.bashrc"
fi

# 8. Export GITHUB_TOKEN for MCP GitHub server
if ! grep -q "GITHUB_TOKEN" "$HOME/.bashrc" 2>/dev/null; then
  echo 'export GITHUB_TOKEN="${GITHUB_TOKEN:-}"' >> "$HOME/.bashrc"
fi

# 9. opencode config output
echo "[nex3] ✅ Setup complete."
echo "[nex3] Workspace: $HOME/opencode-agent3/"
echo "[nex3] Config:   $HOME/opencode-agent3/opencode.json"
echo "[nex3] Inbox:    $HOME/nex-agents/tasks/"
echo "[nex3] Run:      opencode --config $HOME/opencode-agent3/opencode.json"
