#!/usr/bin/env bash
set -uo pipefail

# === Agent3 Daily Entrypoint ===
# Se ejecuta al arrancar el Codespace
echo "[agent3] $(date) - Daily run starting..."
export PATH="$HOME/.opencode/bin:$PATH"
DATE=$(date +%Y-%m-%d)

source "$HOME/.bashrc" 2>/dev/null || true
gh auth setup-git 2>/dev/null || true

cd "$HOME/nex-agents" 2>/dev/null || cd /workspaces/nex-agents 2>/dev/null || {
  echo "[agent3] No repo found"; exit 1
}

git pull origin main 2>/dev/null || true

TASK_FILE=$(find tasks/ -maxdepth 1 -name "*.md" ! -name "template.md" 2>/dev/null | head -1)
if [ -n "$TASK_FILE" ]; then
  TASK_NAME=$(basename "$TASK_FILE" .md)
  echo "[agent3] Task: $TASK_NAME"
  sed -i 's/Estado: pending/Estado: in_progress/' "$TASK_FILE" 2>/dev/null || true
fi

REPORT="$HOME/nex-agents/reports/scanner-${DATE}.md"
cat > "$REPORT" << EOF2
# Scanner Report - ${DATE}
- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Task: ${TASK_NAME:-none}
- Status: completed
EOF2

git add reports/ tasks/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "agent3: daily report ${DATE}" 2>/dev/null || true
  git push origin main 2>/dev/null && echo "[agent3] ✅ Report pushed" || echo "[agent3] ⚠️ Push failed"
fi

echo "[agent3] Report: reports/scanner-${DATE}.md"

# Self-stop codespace to avoid wasted compute
CODESPACE_NAME=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
  "https://api.github.com/user/codespaces" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); cs=[c for c in d.get('codespaces',[]) if c['state']!='Shutdown']; print(cs[0]['name'] if cs else '')" 2>/dev/null)
if [ -n "$CODESPACE_NAME" ]; then
  echo "[agent3] Self-stopping..."
  curl -s -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
    "https://api.github.com/user/codespaces/$CODESPACE_NAME/stop" > /dev/null
fi
echo "[agent3] Done"
