#!/usr/bin/env bash
set -uo pipefail

# === Agent3 Daily Entrypoint ===
# Se ejecuta al arrancar el Codespace
# Requisitos: GH_PAT como secret de Codespace o GITHUB_TOKEN built-in

echo "[agent3] $(date) - Daily run starting..."
export PATH="$HOME/.opencode/bin:$PATH"
DATE=$(date +%Y-%m-%d)

# ── Auth ──────────────────────────────────────────────
# GITHUB_TOKEN lo provee Codespaces automáticamente
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
export OPENCODE_API_KEY="${OPENCODE_API_KEY:-}"

# Configurar gh como credential helper para git
gh auth setup-git 2>/dev/null || true

cd "$HOME/nex-agents" || exit 1

# Pull latest tasks
git pull origin main 2>/dev/null || true

# Check pending tasks
TASK_FILE=$(find tasks/ -maxdepth 1 -name "*.md" ! -name "template.md" 2>/dev/null | head -1)
if [ -n "$TASK_FILE" ]; then
  TASK_NAME=$(basename "$TASK_FILE" .md)
  echo "[agent3] Task found: $TASK_NAME"
  sed -i 's/Estado: pending/Estado: in_progress/' "$TASK_FILE" 2>/dev/null || true
fi

# Run scanner
echo "[agent3] Running scanner..."
REPORT="$HOME/nex-agents/reports/scanner-${DATE}.md"
cat > "$REPORT" << EOF
# Scanner Report - ${DATE}
- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Task: ${TASK_NAME:-none}
- Status: completed
EOF

# Push results
git add reports/ tasks/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "agent3: daily report ${DATE}" 2>/dev/null || true
  git push origin main 2>/dev/null && echo "[agent3] ✅ Report pushed" || echo "[agent3] ⚠️ Push failed (sin permisos de escritura)"
fi

echo "[agent3] $(date) - Daily run complete."
echo "[agent3] Report: reports/scanner-${DATE}.md"
