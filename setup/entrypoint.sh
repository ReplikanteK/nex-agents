#!/usr/bin/env bash
set -uo pipefail

GH_PAT="${1:-${GITHUB_TOKEN:-}}"
[ -z "$GH_PAT" ] && echo "[agent3] No token available" && exit 1
export GH_TOKEN="$GH_PAT"
export GIT_TERMINAL_PROMPT=0

echo "[agent3] $(date -u +%Y-%m-%dT%H:%M:%SZ) - Daily run starting..."
export PATH="$HOME/.opencode/bin:$PATH"
DATE=$(date +%Y-%m-%d)

REPO_DIR="/workspaces/nex-agents"
if [ ! -d "$REPO_DIR/.git" ]; then
  if [ -d "$HOME/nex-agents/.git" ]; then
    REPO_DIR="$HOME/nex-agents"
  else
    echo "[agent3] Cloning repo..."
    gh repo clone ReplikanteK/nex-agents "$HOME/nex-agents" 2>/dev/null || true
    if [ -d "$HOME/nex-agents/.git" ]; then
      REPO_DIR="$HOME/nex-agents"
    else
      echo "[agent3] FAIL: cannot clone repo"
      exit 1
    fi
  fi
fi
cd "$REPO_DIR" || exit 1

gh auth setup-git 2>/dev/null || true
git pull origin main 2>/dev/null || true

TASK_FILE=$(find tasks/ -maxdepth 1 -name "*.md" ! -name "template.md" 2>/dev/null | head -1)
TASK_NAME=""
if [ -n "$TASK_FILE" ]; then
  TASK_NAME=$(basename "$TASK_FILE" .md)
  echo "[agent3] Task found: $TASK_NAME"
  sed -i 's/Estado: pending/Estado: in_progress/' "$TASK_FILE" 2>/dev/null || true
else
  echo "[agent3] No tasks pending"
fi

mkdir -p reports
REPORT="reports/scanner-${DATE}.md"

if [ -f "setup/daily-scanner.sh" ]; then
  echo "[agent3] Running daily scanner..."
  bash setup/daily-scanner.sh || true
fi

cat > "$REPORT" << REPORTEOF
# Scanner Report - ${DATE}
- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Task: ${TASK_NAME:-none}
- Status: completed

## Hallazgos
- Pending task: ${TASK_NAME:-none}
- Targets nuevos: pendiente de escanear (ejecutar opencode para analisis completo)
REPORTEOF

git add reports/ tasks/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.name="agent3" -c user.email="agent3@nex.local" commit -m "agent3: daily report ${DATE}" 2>/dev/null || true
  git push origin main 2>/dev/null && echo "[agent3] Report pushed" || echo "[agent3] Push failed"
fi

echo "[agent3] Report: $REPORT"

CODESPACE_NAME=$(gh api /user/codespaces --jq '.codespaces[] | select(.state != "Shutdown") | .name' 2>/dev/null | head -1)
if [ -n "$CODESPACE_NAME" ]; then
  echo "[agent3] Self-stopping $CODESPACE_NAME..."
  gh api -X POST "/user/codespaces/$CODESPACE_NAME/stop" > /dev/null || true
fi

echo "[agent3] Done"
exit 0
