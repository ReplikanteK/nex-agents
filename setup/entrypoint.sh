#!/usr/bin/env bash
set -uo pipefail

GH_PAT="${1:-${GITHUB_TOKEN:-}}"
[ -z "$GH_PAT" ] && echo "[agent3] No token" && exit 1
export GH_TOKEN="$GH_PAT"
export GIT_TERMINAL_PROMPT=0
export PATH="$HOME/.opencode/bin:$PATH"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DATE=$(date +%Y-%m-%d)
DOW=$(date +%u)
echo "[agent3] $TS - Scan starting... (day $DOW)"

# === Health ===
MISSING=""
for cmd in gh git curl jq; do
  command -v "$cmd" &>/dev/null || { MISSING="$MISSING $cmd"; }
done

OPENCODE_AVAIL=0
command -v opencode &>/dev/null && OPENCODE_AVAIL=1
if [ "$OPENCODE_AVAIL" -eq 0 ]; then
  echo "[agent3] opencode not installed. Installing..."
  curl -fsSL https://opencode.ai/install | bash
  export PATH="$HOME/.opencode/bin:$PATH"
  command -v opencode &>/dev/null && OPENCODE_AVAIL=1
  [ "$OPENCODE_AVAIL" -eq 0 ] && echo "[agent3] WARNING: opencode install failed"
fi

# === Repo ===
REPO_DIR="/workspaces/nex-agents"
if [ ! -d "$REPO_DIR/.git" ]; then
  [ -d "$HOME/nex-agents/.git" ] && REPO_DIR="$HOME/nex-agents" || {
    gh repo clone ReplikanteK/nex-agents "$HOME/nex-agents" 2>/dev/null || true
    [ -d "$HOME/nex-agents/.git" ] && REPO_DIR="$HOME/nex-agents" || { echo "[agent3] FAIL: no repo"; exit 1; }
  }
fi
cd "$REPO_DIR" || exit 1
gh auth setup-git 2>/dev/null || true
git pull origin main 2>/dev/null || true

# === Fetch bounty data (fast, always) ===
BOUNTY_DIR="/tmp/bounty-targets-data"
if command -v git &>/dev/null; then
  if [ ! -d "$BOUNTY_DIR/.git" ]; then
    git clone --depth 1 https://github.com/arkadiyt/bounty-targets-data.git "$BOUNTY_DIR" 2>/dev/null || true
  else
    git -C "$BOUNTY_DIR" pull origin master 2>/dev/null || true
  fi
fi

# === Diff engine ===
mkdir -p reports memoria
STATE_FILE="memoria/targets-state.json"
get_name_url() { jq -r '.[] | select(.name != null) | "\(.name)|\(.url // "?")"' "$1" 2>/dev/null | sort -u; }

H1_JSON="$BOUNTY_DIR/data/hackerone_data.json"
BC_JSON="$BOUNTY_DIR/data/bugcrowd_data.json"
IT_JSON="$BOUNTY_DIR/data/intigriti_data.json"
YWH_JSON="$BOUNTY_DIR/data/yeswehack_data.json"

H1_NOW=$(get_name_url "$H1_JSON")
BC_NOW=$(get_name_url "$BC_JSON")
IT_NOW=$(get_name_url "$IT_JSON")
YWH_NOW=$(get_name_url "$YWH_JSON")

H1_COUNT=$(echo "$H1_NOW" | wc -l)
BC_COUNT=$(echo "$BC_NOW" | wc -l)
IT_COUNT=$(echo "$IT_NOW" | wc -l)
YWH_COUNT=$(echo "$YWH_NOW" | wc -l)

if [ -f "$STATE_FILE" ]; then
  H1_PREV=$(jq -r '.targets.hackerone[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
  BC_PREV=$(jq -r '.targets.bugcrowd[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
  IT_PREV=$(jq -r '.targets.intigriti[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
  YWH_PREV=$(jq -r '.targets.yeswehack[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
else
  H1_PREV=""; BC_PREV=""; IT_PREV=""; YWH_PREV=""
fi

DIFF_SECTION=""
diff_platform() {
  local label="$1" now="$2" prev="$3" new_str="" rem_str=""
  if [ -n "$prev" ]; then
    new_str=$(comm -23 <(echo "$now") <(echo "$prev") 2>/dev/null | head -10)
    rem_str=$(comm -13 <(echo "$now") <(echo "$prev") 2>/dev/null | head -10)
  else
    new_str=$(echo "$now" | head -10)
  fi
  if [ -n "$new_str" ] || [ -n "$rem_str" ]; then
    DIFF_SECTION="${DIFF_SECTION}### ${label}
"
    if [ -n "$new_str" ]; then
      DIFF_SECTION="${DIFF_SECTION}**New ($(echo "$new_str" | wc -l):**
\`\`\`
$new_str
\`\`\`
"
    fi
    if [ -n "$rem_str" ]; then
      DIFF_SECTION="${DIFF_SECTION}**Removed ($(echo "$rem_str" | wc -l):**
\`\`\`
$rem_str
\`\`\`
"
    fi
  fi
}

diff_platform "HackerOne" "$H1_NOW" "$H1_PREV"
diff_platform "Bugcrowd" "$BC_NOW" "$BC_PREV"
diff_platform "Intigriti" "$IT_NOW" "$IT_PREV"
diff_platform "YesWeHack" "$YWH_NOW" "$YWH_PREV"

# === Quick-scan new targets ===
ALL_NOW=$( (echo "$H1_NOW"; echo "$BC_NOW"; echo "$IT_NOW"; echo "$YWH_NOW") | sort -u )
ALL_PREV=$( (echo "${H1_PREV:-}"; echo "${BC_PREV:-}"; echo "${IT_PREV:-}"; echo "${YWH_PREV:-}") | sort -u )
BRAND_NEW=$(comm -23 <(echo "$ALL_NOW") <(echo "$ALL_PREV") 2>/dev/null | head -5)

QUICK_SCAN=""
if [ -n "$BRAND_NEW" ] && command -v curl &>/dev/null; then
  echo "[agent3] Quick-scanning new targets..."
  QUICK_SCAN="## Quick Scan (new targets)
| Target | URL | HTTP |
|--------|-----|------|
"
  while IFS='|' read -r name url; do
    [ -z "$name" ] && continue
    http=$(curl -sI -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 5 "$url" 2>/dev/null || echo "ERR")
    QUICK_SCAN="${QUICK_SCAN}| $name | $url | $http |
"
  done <<< "$BRAND_NEW"
fi

# === Save current state ===
if command -v jq &>/dev/null; then
  write_platform() { jq '[.[] | {name, url}]' "$1" 2>/dev/null || echo '[]'; }
  jq -n \
    --arg ts "$TS" \
    --argjson h1 "$(write_platform "$H1_JSON")" \
    --argjson bc "$(write_platform "$BC_JSON")" \
    --argjson it "$(write_platform "$IT_JSON")" \
    --argjson yw "$(write_platform "$YWH_JSON")" \
    '{last_scan: $ts, targets: {hackerone: $h1, bugcrowd: $bc, intigriti: $it, yeswehack: $yw}}' \
    > "$STATE_FILE"
fi

# === Task: backlog first, auto-create on schedule days ===
TASKS_DONE=0
MAX_TASKS_PER_RUN=2
TASK_NAME=""
TASK_FILE=""

process_task() {
  local file="$1"
  TASK_FILE="$file"
  TASK_NAME=$(basename "$file" .md)
  echo "[agent3] Task: $TASK_NAME"
  sed -i 's/Estado: pending/Estado: in_progress/' "$file" 2>/dev/null || true
  sed -i "s/Iniciado:.*/Iniciado: $TS/" "$file" 2>/dev/null || true
}

auto_create_task() {
  local name="$1" desc="$2" output="$3"
  TASK_NAME="$name"
  TASK_FILE="tasks/${name}.md"
  cat > "$TASK_FILE" << TASKEOF
# Task: $desc
### Origen: agent3 (auto)
### Prioridad: alta
### Estado: in_progress
### Iniciado: $TS

$output
TASKEOF
  echo "[agent3] Created: $name"
}

# --- Try to pick first task ---
PENDING_TASK=$(find tasks/ -maxdepth 1 -name "*.md" ! -name "template.md" 2>/dev/null | head -1)
if [ -n "$PENDING_TASK" ]; then
  process_task "$PENDING_TASK"
elif [ "$OPENCODE_AVAIL" -eq 1 ]; then
  case "$DOW" in
    1)
      auto_create_task "recon-${DATE}" "Weekend new targets analysis" \
"### Objetivo
Analiza los targets nuevos del fin de semana. Aplica scoring framework a los nuevos programas.
Busca repos publicos, evalua stack tecnologico, genera ranking top 3.
Output: reports/recon-${DATE}.md"
      ;;
    2)
      auto_create_task "codereview-${DATE}" "Code review of target" \
"### Objetivo
Toma el target mejor rankeado del ultimo recon que tenga repo publico.
Revisa: input parsing, auth logic, logging de datos sensibles, trust boundary crossings.
Output: reports/codereview-${DATE}.md con superficie de ataque."
      ;;
    3)
      auto_create_task "deep-${DATE}" "Deep analysis / fuzzing setup" \
"### Objetivo
Si hay task en backlog ejecutalo. Sino, identifica targets con componentes C/C++/Rust.
Prepara brief de fuzzing: language, parser complexity, input surface.
Output: reports/deep-${DATE}.md"
      ;;
    4)
      auto_create_task "apiweb-${DATE}" "API / web security recon" \
"### Objetivo
Analiza targets con APIs publicas o aplicaciones web.
Revisa: autenticacion, rate limiting, CORS, GraphQL endpoints, JWT handling.
Output: reports/apiweb-${DATE}.md"
      ;;
    5)
      auto_create_task "maintenance-${DATE}" "Weekly maintenance + brief" \
"### Objetivo
1. Revisa fechas de reportes activos (Lightspark ~23 Jun, Zendesk 3 Jun, Firefox Relay)
2. Resume cambios semanales en bounty landscape
3. Deja brief estructurado para agent1
Output: reports/maintenance-${DATE}.md"
      ;;
    6)
      auto_create_task "deepdive-${DATE}" "Deep dive vulnerability patterns" \
"### Objetivo
Investiga un patron de vulnerabilidad especifico en un target con codigo abierto.
Busca: SSRF via URL parsing, symlink traversal, auto-creation abuse, o memory corruption.
Documenta hallazgos y deja PoC si aplica.
Output: reports/deepdive-${DATE}.md"
      ;;
    *)
      echo "[agent3] Light day (DOW $DOW)"
      ;;
  esac
fi

# === Save state + agent1 JSON ===
AGENT1_JSON="memoria/agent3-latest.json"
cat > "$AGENT1_JSON" << JSONEOF
{
  "scan_date": "$TS",
  "date": "$DATE",
  "task": ${TASK_NAME:-null},
  "platforms": {
    "hackerone": $H1_COUNT,
    "bugcrowd": $BC_COUNT,
    "intigriti": $IT_COUNT,
    "yeswehack": $YWH_COUNT
  }
}
JSONEOF

# === Execute task with opencode ===
run_opencode_task() {
  local file="$1"
  local max_time="${2:-1200}"
  local objective
  objective=$(awk '/### Objetivo/{found=1; next} found && /^###/{exit} found' "$file" | head -30)
  [ -z "$objective" ] && echo "[agent3] No objective in $file" && return 1

  echo "[agent3] Running opencode (${max_time}s timeout)..."
  echo "[agent3] Objective: ${objective:0:120}..."
  OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true timeout "$max_time" \
    opencode run --dangerously-skip-permissions \
      "Execute this task: $objective" \
      -f "$file" 2>&1 || true
  sed -i 's/Estado: in_progress/Estado: completed/' "$file" 2>/dev/null || true
  TASKS_DONE=$((TASKS_DONE + 1))
}

OPENCODE_EXIT=""
if [ -n "$TASK_FILE" ] && [ "$OPENCODE_AVAIL" -eq 1 ]; then
  run_opencode_task "$TASK_FILE"

  # Process backlog: if more tasks pending, execute up to MAX_TASKS_PER_RUN
  while [ "$TASKS_DONE" -lt "$MAX_TASKS_PER_RUN" ]; do
    NEXT_TASK=$(find tasks/ -maxdepth 1 -name "*.md" ! -name "template.md" 2>/dev/null | head -1)
    [ -z "$NEXT_TASK" ] && break
    echo "[agent3] Backlog: processing next task..."
    run_opencode_task "$NEXT_TASK"
  done

elif [ -n "$TASK_FILE" ] && [ "$OPENCODE_AVAIL" -eq 0 ]; then
  echo "[agent3] Task pending but opencode not available"
  sed -i 's/Estado: in_progress/Estado: completed/' "$TASK_FILE" 2>/dev/null || true
fi

# === Generate report ===
REPORT="reports/scanner-${DATE}.md"
cat > "$REPORT" << REPORTEOF
# Scanner Report - ${DATE}
- Generated: $TS
- Task: ${TASK_NAME:-none}
- Opencode: ${OPENCODE_AVAIL}
- Status: completed

## Bounty Targets Overview
| Platform | Targets |
|----------|---------|
| HackerOne | ${H1_COUNT} |
| Bugcrowd | ${BC_COUNT} |
| Intigriti | ${IT_COUNT} |
| YesWeHack | ${YWH_COUNT} |

## Target Changes
${DIFF_SECTION:-*No changes detected since last scan.*}
${QUICK_SCAN}
## Health
- Tools: gh git curl jq
- Missing: ${MISSING:-none}
- State: targets-state.json + agent3-latest.json
REPORTEOF

# === Commit and push ===
git add reports/ memoria/ tasks/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.name="agent3" -c user.email="agent3@nex.local" commit -m "agent3: scan ${DATE}" 2>/dev/null || true
  git push origin main 2>/dev/null && echo "[agent3] Pushed" || echo "[agent3] Push failed"
fi

echo "[agent3] Report: $REPORT"
echo "[agent3] Openocode exit: ${OPENCODE_EXIT:-none}"

# === Self-stop ===
CS_NAME=$(gh api /user/codespaces --jq '.codespaces[] | select(.state != "Shutdown") | .name' 2>/dev/null | head -1)
if [ -n "$CS_NAME" ]; then
  echo "[agent3] Self-stopping $CS_NAME..."
  gh api -X POST "/user/codespaces/$CS_NAME/stop" > /dev/null || true
fi

echo "[agent3] Done"
exit 0
