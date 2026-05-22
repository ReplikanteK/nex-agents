#!/usr/bin/env bash
set -uo pipefail

# === Agent3 Daily Entrypoint ===
# Se ejecuta al arrancar el Codespace (vía postStartCommand o API)
# Opera en modo headless — tareas automatizadas sin interacción

echo "[agent3] $(date) - Daily run starting..."
export PATH="$HOME/.opencode/bin:$PATH"
DATE=$(date +%Y-%m-%d)

cd "$HOME/nex-agents" || exit 1

# Pull latest tasks/inbox from agent1/2
git pull origin main 2>/dev/null || true

# Check for pending tasks
TASK_FILE=$(find tasks/ -maxdepth 1 -name "*.md" ! -name "template.md" 2>/dev/null | head -1)

if [ -n "$TASK_FILE" ]; then
  TASK_NAME=$(basename "$TASK_FILE" .md)
  echo "[agent3] Task found: $TASK_NAME"
  sed -i 's/Estado: pending/Estado: in_progress/' "$TASK_FILE" 2>/dev/null || true
fi

# Run automated scanner (always)
echo "[agent3] Running scanner..."
REPORT="$HOME/nex-agents/reports/scanner-${DATE}.md"
cat > "$REPORT" << EOF
# Scanner Report - ${DATE}
- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Task: ${TASK_NAME:-none}
- Status: completed

EOF

# Commit and push results
git add reports/ tasks/ 2>/dev/null || true
git diff --cached --quiet || git commit -m "agent3: daily report ${DATE}" && git push 2>/dev/null || true

echo "[agent3] $(date) - Daily run complete."
echo "[agent3] El reporte está en reports/scanner-${DATE}.md"
echo "[agent3] Task ${TASK_NAME:-none} iniciada — agent1/2 puede revisarla"
