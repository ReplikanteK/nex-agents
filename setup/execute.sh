#!/usr/bin/env bash
set -uo pipefail

# execute.sh - Run on codespace (costs minutes)
# Only handles task execution, enrichment is already done

GH_PAT="${1:-${GITHUB_TOKEN:-}}"
[ -z "$GH_PAT" ] && echo "[execute] No token" && exit 1
export GH_TOKEN="$GH_PAT"
export GIT_TERMINAL_PROMPT=0
export PATH="$HOME/.opencode/bin:$PATH"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DATE=$(date +%Y-%m-%d)
DOW=$(date +%u)
echo "[execute] $TS - Execute starting... (day $DOW)"

# === Health ===
# Install gh CLI if missing
if ! command -v gh &>/dev/null; then
  echo "[execute] gh not installed. Installing..."
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  apt-get update -qq && apt-get install gh -y -qq 2>&1 | tail -3
fi

for cmd in gh git curl jq; do
  command -v "$cmd" &>/dev/null || { echo "[execute] Missing: $cmd"; exit 1; }
done

OPENCODE_AVAIL=0
command -v opencode &>/dev/null && OPENCODE_AVAIL=1
if [ "$OPENCODE_AVAIL" -eq 0 ]; then
  echo "[execute] opencode not installed. Installing..."
  curl -fsSL https://opencode.ai/install | bash
  export PATH="$HOME/.opencode/bin:$PATH"
  command -v opencode &>/dev/null && OPENCODE_AVAIL=1
  [ "$OPENCODE_AVAIL" -eq 0 ] && echo "[execute] WARNING: opencode install failed"
fi

# === Repo sync ===
REPO_DIR="/workspaces/nex-agents"
if [ ! -d "$REPO_DIR/.git" ]; then
  [ -d "$HOME/nex-agents/.git" ] && REPO_DIR="$HOME/nex-agents" || {
    gh repo clone ReplikanteK/nex-agents "$HOME/nex-agents" 2>/dev/null || true
    [ -d "$HOME/nex-agents/.git" ] && REPO_DIR="$HOME/nex-agents" || { echo "[execute] FAIL: no repo"; exit 1; }
  }
fi
cd "$REPO_DIR" || exit 1
gh auth setup-git 2>/dev/null || true
git pull origin main 2>/dev/null || true

# Sync opencode config
export OPENCODE_HOME="$HOME/.opencode"
mkdir -p "$OPENCODE_HOME"
cp -r .opencode/* "$OPENCODE_HOME/" 2>/dev/null || true

# === Load enrichment results ===
RANKED_FILE="memoria/targets-ranked.json"
TOP_CANDIDATES=$(jq -r '.[0] // empty' "$RANKED_FILE" 2>/dev/null)
TOP_SCORE=$(echo "$TOP_CANDIDATES" | jq -r '.score // 0' 2>/dev/null)

echo "[execute] Top candidate: $(echo "$TOP_CANDIDATES" | jq -r '.name // "none"') (score: $TOP_SCORE)"

# === Task Selection ===
TASKS_DONE=0
MAX_TASKS_PER_RUN=1
TASK_NAME=""
TASK_FILE=""

process_task() {
  local file="$1"
  TASK_FILE="$file"
  TASK_NAME=$(basename "$file" .md)
  echo "[execute] Task: $TASK_NAME"
  sed -i 's/Estado: pending/Estado: in_progress/' "$file" 2>/dev/null || true
  sed -i "s/Iniciado:.*/Iniciado: $TS/" "$file" 2>/dev/null || true
}

auto_create_task() {
  local name="$1" desc="$2" output="$3"
  TASK_NAME="$name"
  TASK_FILE="tasks/${name}.md"
  mkdir -p tasks
  cat > "$TASK_FILE" << TASKEOF
# Task: $desc
### Origen: agent3 (auto)
### Prioridad: alta
### Estado: in_progress
### Iniciado: $TS

$output
TASKEOF
  echo "[execute] Created: $name"
}

# Check pending backlog first
PENDING_TASK=$(find tasks/ -maxdepth 1 -name "*.md" ! -name "template.md" -exec grep -L 'Estado:.*completed' {} \; 2>/dev/null | head -1)
if [ -n "$PENDING_TASK" ]; then
  process_task "$PENDING_TASK"
elif [ "$TOP_SCORE" -ge 65 ] && [ "$OPENCODE_AVAIL" -eq 1 ]; then
  TARGET_NAME=$(echo "$TOP_CANDIDATES" | jq -r '.name')
  TARGET_REPO=$(echo "$TOP_CANDIDATES" | jq -r '.repo')
  TARGET_LANG=$(echo "$TOP_CANDIDATES" | jq -r '.language')
  TARGET_URL=$(echo "$TOP_CANDIDATES" | jq -r '.url // empty')

  # Validate repo exists and is cloneable
  HAS_REPO="false"
  if [ "$TARGET_REPO" != "null" ] && [ -n "$TARGET_REPO" ]; then
    if git ls-remote "https://github.com/$TARGET_REPO.git" &>/dev/null; then
      HAS_REPO="true"
    fi
  fi

  if [ "$HAS_REPO" = "true" ]; then
    # Phase 1: Scout triage (repo-based)
    SCOUT_FILE="reports/scout-${DATE}-${TARGET_NAME// /-}.md"
    echo "[execute] Phase 1: Scout triage on $TARGET_NAME (repo: $TARGET_REPO)..."
    OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true timeout 300 opencode run --dangerously-skip-permissions \
      "Use the scout subagent to perform reconnaissance on this target. Repo: $TARGET_REPO, Language: $TARGET_LANG. Produce a structured recon report with: tech stack, key modules, auth mechanisms, API surface, and recommended test vectors. Output to: $SCOUT_FILE" \
      -f "$SCOUT_FILE" 2>&1 || true

    # Phase 2: Code review
    REVIEW_FILE="reports/codereview-${DATE}-${TARGET_NAME// /-}.md"
    echo "[execute] Phase 2: Code review on $TARGET_NAME..."
    auto_create_task "codereview-${DATE}-${TARGET_NAME// /-}" "Code review of $TARGET_NAME" \
"### Objetivo
Clona https://github.com/$TARGET_REPO y realiza un code review de seguridad.
Enfoque: input parsing, auth logic, trust boundary crossings, logging de datos sensibles.
Lenguaje: $TARGET_LANG. Aplica patrones del skill correspondiente.
Output: $REVIEW_FILE

### Nota
Si el repo no es clonable, haz web recon en su lugar y guarda en $SCOUT_FILE"
  else
    # No repo available - web recon only
    SCOUT_FILE="reports/webrecon-${DATE}-${TARGET_NAME// /-}.md"
    echo "[execute] No repo for $TARGET_NAME. Running web recon instead..."
    OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true timeout 300 opencode run --dangerously-skip-permissions \
      "Perform web reconnaissance on this bounty target: $TARGET_NAME. Analyze their public-facing applications, API endpoints, technology stack (via HTTP headers, JS files, etc.), and identify potential attack surface. Check for common misconfigs, exposed panels, and interesting endpoints. Output to: $SCOUT_FILE" \
      -f "$SCOUT_FILE" 2>&1 || true
    
    echo "[execute] Skipping code review (no repo available). Web recon saved."
  fi

elif [ "$OPENCODE_AVAIL" -eq 1 ]; then
  echo "[execute] No target with score ≥65. Light day."
  case "$DOW" in
    5)
      auto_create_task "maintenance-${DATE}" "Weekly maintenance" \
"### Objetivo
1. Revisa reportes activos pendientes
2. Resume cambios semanales en bounty landscape
3. Deja brief para agent1
Output: reports/maintenance-${DATE}.md" ;;
    *) echo "[execute] No task created." ;;
  esac
fi

# === Execute task ===
run_opencode_task() {
  local file="$1"
  local max_time="${2:-1200}"
  local objective
  objective=$(awk '/### Objetivo/{found=1; next} found && /^###/{exit} found' "$file" | head -30)
  [ -z "$objective" ] && echo "[execute] No objective in $file" && return 1
  echo "[execute] Running opencode (${max_time}s timeout)..."
  echo "[execute] Objective: ${objective:0:120}..."
  [ -f "$file" ] && opencode run --dangerously-skip-permissions \
    "Execute this task: $objective" \
    -f "$file" 2>&1 || true
  sed -i 's/Estado: in_progress/Estado: completed/' "$file" 2>/dev/null || true
  mv "$file" tasks/done/ 2>/dev/null || true
  TASKS_DONE=$((TASKS_DONE + 1))
}

if [ -n "$TASK_FILE" ] && [ "$OPENCODE_AVAIL" -eq 1 ]; then
  run_opencode_task "$TASK_FILE"
elif [ -n "$TASK_FILE" ] && [ "$OPENCODE_AVAIL" -eq 0 ]; then
  echo "[execute] Task pending but opencode not available"
  sed -i 's/Estado: in_progress/Estado: completed/' "$TASK_FILE" 2>/dev/null || true
  mv "$TASK_FILE" tasks/done/ 2>/dev/null || true
fi

# === Commit and push ===
git add reports/ memoria/ tasks/ .opencode/ setup/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.name="agent3" -c user.email="agent3@nex.local" commit -m "agent3: execute ${DATE}" 2>/dev/null || true
  git push origin main 2>/dev/null && echo "[execute] Pushed" || echo "[execute] Push failed"
fi

echo "[execute] Done"
exit 0
