#!/usr/bin/env bash
set -uo pipefail

GH_PAT="${1:-${GITHUB_TOKEN:-}}"
[ -z "$GH_PAT" ] && echo "[agent3] No token available" && exit 1
export GH_TOKEN="$GH_PAT"
export GIT_TERMINAL_PROMPT=0

echo "[agent3] $(date -u +%Y-%m-%dT%H:%M:%SZ) - Daily run starting..."
export PATH="$HOME/.opencode/bin:$PATH"
DATE=$(date +%Y-%m-%d)

# === Health check ===
echo "[agent3] Health check..."
MISSING=""
for cmd in gh git curl jq; do
  command -v "$cmd" &>/dev/null || { MISSING="$MISSING $cmd"; echo "[agent3] WARNING: $cmd not found"; }
done
[ -n "$MISSING" ] && echo "[agent3] Missing tools:$MISSING (some features disabled)"

# === Locate repo ===
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

# === Detect task ===
TASK_FILE=$(find tasks/ -maxdepth 1 -name "*.md" ! -name "template.md" 2>/dev/null | head -1)
TASK_NAME=""
if [ -n "$TASK_FILE" ]; then
  TASK_NAME=$(basename "$TASK_FILE" .md)
  echo "[agent3] Task found: $TASK_NAME"
  sed -i 's/Estado: pending/Estado: in_progress/' "$TASK_FILE" 2>/dev/null || true
else
  echo "[agent3] No tasks pending"
fi

# === Report directory ===
mkdir -p reports
REPORT="reports/scanner-${DATE}.md"

# === Fetch bounty-targets-data for real metrics ===
BOUNTY_DIR="/tmp/bounty-targets-data"
echo "[agent3] Fetching bounty-targets-data..."
if command -v git &>/dev/null; then
  if [ ! -d "$BOUNTY_DIR/.git" ]; then
    git clone --depth 1 https://github.com/arkadiyt/bounty-targets-data.git "$BOUNTY_DIR" 2>/dev/null || echo "[agent3] bounty-targets-data clone failed"
  else
    git -C "$BOUNTY_DIR" pull origin master 2>/dev/null || true
  fi
fi

# === Parse bounty stats ===
H1_COUNT="?"
BC_COUNT="?"
IT_COUNT="?"
YWH_COUNT="?"
if command -v jq &>/dev/null && [ -d "$BOUNTY_DIR/data" ]; then
  H1_COUNT=$(jq '. | length' "$BOUNTY_DIR/data/hackerone_data.json" 2>/dev/null || echo "?")
  BC_COUNT=$(jq '. | length' "$BOUNTY_DIR/data/bugcrowd_data.json" 2>/dev/null || echo "?")
  IT_COUNT=$(jq '. | length' "$BOUNTY_DIR/data/intigriti_data.json" 2>/dev/null || echo "?")
  YWH_COUNT=$(jq '. | length' "$BOUNTY_DIR/data/yeswehack_data.json" 2>/dev/null || echo "?")
fi

# === Generate report ===
cat > "$REPORT" << REPORTEOF
# Scanner Report - ${DATE}
- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Task: ${TASK_NAME:-none}
- Status: completed

## Bounty Targets Overview
| Platform | Targets |
|----------|---------|
| HackerOne | ${H1_COUNT} |
| Bugcrowd | ${BC_COUNT} |
| Intigriti | ${IT_COUNT} |
| YesWeHack | ${YWH_COUNT} |

## Health
- Tools: gh git curl jq
REPORTEOF

# === Run daily scanner if available ===
if [ -f "setup/daily-scanner.sh" ]; then
  echo "[agent3] Running daily scanner..."
  bash setup/daily-scanner.sh || true
fi

# === Commit and push report ===
git add reports/ tasks/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.name="agent3" -c user.email="agent3@nex.local" commit -m "agent3: daily report ${DATE}" 2>/dev/null || true
  git push origin main 2>/dev/null && echo "[agent3] Report pushed" || echo "[agent3] Push failed"
fi

echo "[agent3] Report: $REPORT"

# === Self-stop ===
CODESPACE_NAME=$(gh api /user/codespaces --jq '.codespaces[] | select(.state != "Shutdown") | .name' 2>/dev/null | head -1)
if [ -n "$CODESPACE_NAME" ]; then
  echo "[agent3] Self-stopping $CODESPACE_NAME..."
  gh api -X POST "/user/codespaces/$CODESPACE_NAME/stop" > /dev/null || true
fi

echo "[agent3] Done"
exit 0
