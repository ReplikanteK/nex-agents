#!/usr/bin/env bash
set -euo pipefail

# === Agent3 Setup Script ===
# Run ONCE on a fresh Codespace to bootstrap agent3

echo "[nex3] Setting up Agent3 environment..."

# 1. Install opencode CLI
if ! command -v opencode &>/dev/null; then
  echo "[nex3] Installing opencode..."
  npm install -g @anthropic-ai/cli-opencode
fi

# 2. Set up GitHub token from Codespace secret
if [ -n "$GITHUB_TOKEN" ]; then
  mkdir -p ~/.local/share/opencode-agent
  echo "$GITHUB_TOKEN" > ~/.local/share/opencode-agent/token
  chmod 600 ~/.local/share/opencode-agent/token
  echo "[nex3] Token configurado"
fi

# 3. Clone nex-agents (inbox/outbox)
if [ ! -d ~/nex-agents ]; then
  git clone https://github.com/ReplikanteK/nex-agents.git ~/nex-agents
fi

# 4. Clone agent1 workspace (read-only)
if [ ! -d ~/opencode-agent ]; then
  git clone https://github.com/ReplikanteK/nex-memoria.git ~/opencode-agent/memoria
fi

# 5. Create agent3 workspace
mkdir -p ~/opencode-agent3/{tasks,reports,fuzzing,scanner,memoria}

# 6. Set up opencode.json
cat > ~/opencode-agent3/opencode.json << 'JSONEOF'
{
  "provider": "opencode",
  "model": "deepseek-v4-flash-free",
  "compaction": {
    "auto": true,
    "tail_turns": 15
  },
  "mcpServers": {
    "memory": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-memory"],
      "environment": {
        "MEMORY_FILE_PATH": "/home/freeman/opencode-agent3/memoria/memory.jsonl"
      }
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"]
    }
  }
}
JSONEOF

# 7. Symlink skills from shared config
if [ ! -L ~/opencode-agent3/.opencode ]; then
  ln -sf ~/opencode-agent/.opencode ~/opencode-agent3/.opencode 2>/dev/null || true
fi

echo "[nex3] ✅ Setup complete. Agent3 ready."
echo "[nex3] Run: opencode --config ~/opencode-agent3/opencode.json"
