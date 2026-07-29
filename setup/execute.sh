#!/usr/bin/env bash
set -uo pipefail

# execute.sh - Execute security analysis on selected target
# Runs on Codespace (with opencode)
# Uses personalized selection from agent3-latest.json

GH_PAT="${1:-${GITHUB_TOKEN:-}}"
[ -z "$GH_PAT" ] && echo "[execute] No token" && exit 1
export GH_TOKEN="$GH_PAT"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[execute] $TS - Starting personalized execution..."

# === Ensure opencode is in PATH (SSH non-interactive shells don't source .bashrc) ===
export PATH="$HOME/.opencode/bin:$PATH"

# === Auto-install gh CLI (wait for apt lock — bootstrap.sh may be running concurrently) ===
if ! command -v gh &>/dev/null; then
  echo "[execute] Installing gh CLI..."
  SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  for i in $(seq 1 30); do
    $SUDO apt-get check 2>/dev/null && break
    echo "[execute] Waiting for apt lock (attempt $i)..."
    sleep 2
  done
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg 2>/dev/null | $SUDO dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | $SUDO tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  $SUDO apt-get update -qq 2>/dev/null && $SUDO apt-get install gh -y -qq 2>&1 | tail -3
fi

# === Setup git auth ===
gh auth setup-git 2>/dev/null || true
git pull origin main 2>/dev/null || true

# === Auto-install opencode (fallback — bootstrap.sh may not have finished) ===
if ! command -v opencode &>/dev/null; then
  echo "[execute] Installing opencode..."
  curl -fsSL https://opencode.ai/install | bash
  export PATH="$HOME/.opencode/bin:$PATH"
fi

# === Health check ===
for cmd in gh git curl jq opencode; do
  command -v "$cmd" &>/dev/null || { echo "[execute] Missing: $cmd"; exit 1; }
done

# === Load configuration ===
REPO_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$REPO_DIR" || exit 1

# Load K Profile
K_PROFILE="memoria/k-profile.json"
if [ ! -f "$K_PROFILE" ]; then
  echo "[execute] ERROR: K-profile not found"
  exit 1
fi

# Load agent3-latest.json
AGENT3_FILE="memoria/agent3-latest.json"
if [ ! -f "$AGENT3_FILE" ]; then
  echo "[execute] ERROR: agent3-latest.json not found"
  exit 1
fi

# === Check for pending manual tasks ===
TASKS_DIR="tasks"
PENDING_TASKS=$(find "$TASKS_DIR" -name "*.md" -not -path "*/done/*" 2>/dev/null | head -1)

if [ -n "$PENDING_TASKS" ]; then
  echo "[execute] Found pending task: $PENDING_TASKS"
  TASK_FILE="$PENDING_TASKS"
else
  echo "[execute] No pending tasks, checking selected targets..."
  
  # === Get selected target from personalized selection ===
  SELECTED_TARGET=$(jq -r '.selected_targets[0] // empty' "$AGENT3_FILE" 2>/dev/null)
  
  if [ -z "$SELECTED_TARGET" ]; then
    echo "[execute] No selected targets available"
    echo "[execute] Light day - no work to do"
    exit 0
  fi
  
  # Extract target info
  TARGET_NAME=$(echo "$SELECTED_TARGET" | jq -r '.name // ""')
  TARGET_PLATFORM=$(echo "$SELECTED_TARGET" | jq -r '.platform // ""')
  TARGET_SCORE=$(echo "$SELECTED_TARGET" | jq -r '.score_total // 0')
  TARGET_WHY=$(echo "$SELECTED_TARGET" | jq -r '.justification.why // "Selected by personalized scoring"')
  TARGET_SKILLS=$(echo "$SELECTED_TARGET" | jq -r '.justification.skills_to_apply | join(", ") // "web-security,api-testing"')
  TARGET_HOURS=$(echo "$SELECTED_TARGET" | jq -r '.justification.estimated_hours // 4')
  TARGET_BOUNTY=$(echo "$SELECTED_TARGET" | jq -r '.justification.estimated_bounty // 1000')
  
  echo "[execute] Selected target: $TARGET_NAME ($TARGET_PLATFORM)"
  echo "[execute] Score: $TARGET_SCORE"
  echo "[execute] Why: $TARGET_WHY"
  echo "[execute] Skills to apply: $TARGET_SKILLS"
  echo "[execute] Estimated hours: $TARGET_HOURS"
  echo "[execute] Estimated bounty: \$$TARGET_BOUNTY"
  
  # Create task file (compact — 25 min budget, Codespace free tier)
  TASK_FILE="tasks/$(date +%Y%m%d)-${TARGET_NAME// /-}.md"
  cat > "$TASK_FILE" << TASKEOF
# Task: Quick Scan - $TARGET_NAME

## Target
- **Name**: $TARGET_NAME
- **Platform**: $TARGET_PLATFORM
- **Score**: $TARGET_SCORE
- **Skills**: $TARGET_SKILLS

## Goal (25 min)
Find 1 confirmed vulnerability with PoC. Prioritize what you can do fastest: auth logic, URL validation, file handling, or API authorization.

## Steps
1. Quick recon — identify attack surface (5 min)
2. Targeted code review — 1-2 vulnerability classes (15 min)
3. PoC if found — minimal reproduction (5 min)

## Output
- Finding description and impact
- PoC commands or code
- Draft report ready for submission
TASKEOF
  
  echo "[execute] Task created: $TASK_FILE"
fi

# === Execute task with opencode ===
echo "[execute] Running opencode on task..."
TIMEOUT=2700  # 45 minutes (codespace free tier: ~30h/mo, esto permite ~22 runs)

if timeout $TIMEOUT opencode run --dangerously-skip-permissions "$TASK_FILE" 2>&1; then
  echo "[execute] Task completed successfully"
  
  # Move to done
  mv "$TASK_FILE" "tasks/done/$(basename "$TASK_FILE")" 2>/dev/null || true
  
  # Auto-close failure issues for this target (clean slate for recovery)
  TASK_BASENAME=$(basename "$TASK_FILE")
  gh issue list --repo "ReplikanteK/nex-agents" --state open --search "Execute Failure: $TASK_BASENAME" --json number 2>/dev/null | jq -r '.[].number' | while read num; do
    [ -n "$num" ] && gh issue close "$num" --comment "Resolved: execute completed at $TS" 2>/dev/null || true
  done
  
  # Git commit
  git add tasks/ memoria/ reports/ 2>/dev/null || true
  if ! git diff --cached --quiet 2>/dev/null; then
    git -c user.name="execute-bot" -c user.email="execute@nex.local" commit -m "execute: completed task $(basename "$TASK_FILE")" 2>/dev/null || true
    git push origin main 2>/dev/null && echo "[execute] Pushed" || echo "[execute] Push failed"
  fi
  
  echo "[execute] Done"
  exit 0
else
  echo "[execute] Task failed or timed out"
  
  # Create failure issue
  FAIL_MSG="Task failed: $(basename "$TASK_FILE") at $TS"
  gh issue create --title "Execute Failure: $(basename "$TASK_FILE")" --body "$FAIL_MSG" 2>/dev/null || true
  
  exit 1
fi
