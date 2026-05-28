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

# === Repo + config sync ===
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

# Sync opencode config (skills + agents) for this run
export OPENCODE_HOME="$HOME/.opencode"
mkdir -p "$OPENCODE_HOME"
cp -r .opencode/* "$OPENCODE_HOME/" 2>/dev/null || true

# === Fetch bounty data ===
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

# diff logic (same as before)
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
    [ -n "$new_str" ] && DIFF_SECTION="${DIFF_SECTION}**New ($(echo "$new_str" | wc -l):**\n\`\`\`\n$new_str\n\`\`\`\n"
    [ -n "$rem_str" ] && DIFF_SECTION="${DIFF_SECTION}**Removed ($(echo "$rem_str" | wc -l):**\n\`\`\`\n$rem_str\n\`\`\`\n"
  fi
}
diff_platform "HackerOne" "$H1_NOW" "$H1_PREV"
diff_platform "Bugcrowd" "$BC_NOW" "$BC_PREV"
diff_platform "Intigriti" "$IT_NOW" "$IT_PREV"
diff_platform "YesWeHack" "$YWH_NOW" "$YWH_PREV"

# === Save full state ===
write_platform() { jq '[.[] | {name, url}]' "$1" 2>/dev/null || echo '[]'; }
jq -n --arg ts "$TS" --argjson h1 "$(write_platform "$H1_JSON")" --argjson bc "$(write_platform "$BC_JSON")" --argjson it "$(write_platform "$IT_JSON")" --argjson yw "$(write_platform "$YWH_JSON")" '{last_scan: $ts, targets: {hackerone: $h1, bugcrowd: $bc, intigriti: $it, yeswehack: $yw}}' > "$STATE_FILE"

# =====================================================================
# NEW: GitHub Enrichment + Scoring Pipeline
# =====================================================================
echo "[agent3] Enriching targets with GitHub API..."

RANKED_FILE="memoria/targets-ranked.json"
SCORED_CANDIDATES="[]"

# Extract all unique scopes with github.com URLs from the raw data
# We look in the original bounty-targets-data JSON for asset identifiers
extract_github_repos() {
  local json="$1"
  jq -r '[.[] | select(.name != null) | {name: .name, url: .url, assets: (.assets // [])}] | .[] | select(.assets[] | test("github\\.com"; "i")) | {name, repo: (.assets[] | select(test("github\\.com"; "i")))}' "$json" 2>/dev/null
}

score_target() {
  local name="$1" repo="$2" lang="$3" size="$4" stars="$5" pushed="$6" bounty="$7"
  # Bounty economics (0-25)
  local eco=10; [[ "$bounty" == "paid" ]] && eco=20
  # Code accessibility (0-25): language match + size + active
  local code=0
  case "$lang" in
    "Python") code=22 ;;
    "Go")     code=20 ;;
    "C"|"C++"|"Rust") code=18 ;;
    "TypeScript"|"JavaScript") code=14 ;;
    "Java")   code=12 ;;
    *)        code=8 ;;
  esac
  # >50k lines penalty
  [ "$size" -gt 50000 ] && code=$((code - 8))
  # Stale repo penalty (>6 months)
  local stale=$(date -d "$pushed" +%s 2>/dev/null || echo 0)
  local now=$(date +%s)
  [ $(( (now - stale) / 86400 )) -gt 180 ] && code=$((code - 4))
  [ "$code" -lt 0 ] && code=0

  # Attack surface (0-25): stars as proxy for complexity
  local surface=10
  [ "$stars" -lt 1000 ] && surface=20
  [ "$stars" -lt 500 ] && surface=22
  [ "$stars" -gt 10000 ] && surface=12

  # Likelihood (0-25): active + small + our languages
  local like=10
  [ "$size" -lt 30000 ] && like=$((like + 5))
  [ "$size" -lt 10000 ] && like=$((like + 5))
  case "$lang" in "Python"|"Go"|"C"|"C++") like=$((like + 5)) ;; esac
  [ "$like" -gt 25 ] && like=25

  local total=$((eco + code + surface + like))
  echo "$total"
}

# Iterate over all platforms and find targets with GitHub repos
echo "[" > "$RANKED_FILE.tmp"
first=true
for platform in hackerone bugcrowd intigriti yeswehack; do
  case "$platform" in
    hackerone) JSON="$H1_JSON"; BPLABEL="H1" ;;
    bugcrowd)  JSON="$BC_JSON"; BPLABEL="BC" ;;
    intigriti) JSON="$IT_JSON"; BPLABEL="IT" ;;
    yeswehack) JSON="$YWH_JSON"; BPLABEL="YWH" ;;
  esac
  [ ! -f "$JSON" ] && continue

  # Extract name + github URL from each program's assets
  jq -c '.[] | select(.assets != null) | {name, url, assets: .assets}' "$JSON" 2>/dev/null | while read -r prog; do
    pname=$(echo "$prog" | jq -r '.name')
    purl=$(echo "$prog" | jq -r '.url')
    assets=$(echo "$prog" | jq -r '.assets[]' 2>/dev/null)
    echo "$assets" | while read -r asset; do
      # Match github.com URLs
      ghurl=$(echo "$asset" | grep -io 'https\?://github.com/[A-Za-z0-9_.-]\+/[A-Za-z0-9_.-]\+' 2>/dev/null || true)
      [ -z "$ghurl" ] && continue
      # Normalize: remove trailing .git, trailing /
      ghurl=$(echo "$ghurl" | sed 's/\.git$//; s/\/$//')
      owner_repo=$(echo "$ghurl" | sed 's|https\?://github.com/||')

      # Query GitHub API
      api_resp=$(curl -s -H "Authorization: token $GH_PAT" "https://api.github.com/repos/$owner_repo" 2>/dev/null)
      lang=$(echo "$api_resp" | jq -r '.language // "unknown"')
      size=$(echo "$api_resp" | jq -r '.size // 0')
      stars=$(echo "$api_resp" | jq -r '.stargazers_count // 0')
      pushed=$(echo "$api_resp" | jq -r '.pushed_at // ""')
      message=$(echo "$api_resp" | jq -r '.message // ""')
      [ "$message" = "Not Found" ] && continue

      bounty_status="unknown"
      # H1/BC managed programs almost always paid
      case "$platform" in
        hackerone) bounty_status="paid" ;;
        bugcrowd)  bounty_status="paid" ;;
        intigriti) bounty_status="paid" ;;
        yeswehack) bounty_status="paid" ;;
      esac

      score=$(score_target "$pname" "$ghurl" "$lang" "$size" "$stars" "$pushed" "$bounty_status")

      entry="{\"name\":\"$pname\",\"platform\":\"$BPLABEL\",\"url\":\"$purl\",\"repo\":\"$ghurl\",\"language\":\"$lang\",\"size_kb\":$size,\"stars\":$stars,\"pushed_at\":\"$pushed\",\"score\":$score,\"bounty\":\"$bounty_status\",\"scored_at\":\"$TS\"}"
      if [ "$first" = true ]; then echo "$entry" >> "$RANKED_FILE.tmp"; first=false; else echo ",$entry" >> "$RANKED_FILE.tmp"; fi
    done
  done
done
echo "]" >> "$RANKED_FILE.tmp"

# Sort by score descending and take top 10
jq -s 'add | sort_by(-.score) | .[:10]' "$RANKED_FILE.tmp" 2>/dev/null > "$RANKED_FILE" || echo '[]' > "$RANKED_FILE"
rm -f "$RANKED_FILE.tmp"

TOP_CANDIDATES=$(jq -r '.[0] // empty' "$RANKED_FILE" 2>/dev/null)
TOP_SCORE=$(echo "$TOP_CANDIDATES" | jq -r '.score // 0' 2>/dev/null)

echo "[agent3] Top candidate: $(echo "$TOP_CANDIDATES" | jq -r '.name // "none"') (score: $TOP_SCORE)"

# === Quick-scan new targets (same as before, for report) ===
ALL_NOW=$( (echo "$H1_NOW"; echo "$BC_NOW"; echo "$IT_NOW"; echo "$YWH_NOW") | sort -u)
ALL_PREV=$( (echo "${H1_PREV:-}"; echo "${BC_PREV:-}"; echo "${IT_PREV:-}"; echo "${YWH_PREV:-}") | sort -u)
BRAND_NEW=$(comm -23 <(echo "$ALL_NOW") <(echo "$ALL_PREV") 2>/dev/null | head -5)
QUICK_SCAN=""
if [ -n "$BRAND_NEW" ] && command -v curl &>/dev/null; then
  echo "[agent3] Quick-scanning new targets..."
  QUICK_SCAN="## Quick Scan (new targets)\n| Target | URL | HTTP |\n|--------|-----|------|\n"
  while IFS='|' read -r name url; do
    [ -z "$name" ] && continue
    http=$(curl -sI -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 5 "$url" 2>/dev/null || echo "ERR")
    QUICK_SCAN="${QUICK_SCAN}| $name | $url | $http |\n"
  done <<< "$BRAND_NEW"
fi

# =====================================================================
# TASK SELECTION: only if candidate ≥ 70
# =====================================================================
TASKS_DONE=0
MAX_TASKS_PER_RUN=1
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
  mkdir -p tasks
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

# Check pending backlog first
PENDING_TASK=$(find tasks/ -maxdepth 1 -name "*.md" ! -name "template.md" 2>/dev/null | head -1)
if [ -n "$PENDING_TASK" ]; then
  process_task "$PENDING_TASK"
elif [ "$TOP_SCORE" -ge 70 ] && [ "$OPENCODE_AVAIL" -eq 1 ]; then
  TARGET_NAME=$(echo "$TOP_CANDIDATES" | jq -r '.name')
  TARGET_REPO=$(echo "$TOP_CANDIDATES" | jq -r '.repo')
  TARGET_LANG=$(echo "$TOP_CANDIDATES" | jq -r '.language')

  # Phase 1: Scout triage
  SCOUT_FILE="reports/scout-${DATE}-${TARGET_NAME// /-}.md"
  echo "[agent3] Phase 1: Scout triage on $TARGET_NAME..."
  OPENCODE_DANGEROUSLY_SKIP_PERMISSIONS=true timeout 300 opencode run --dangerously-skip-permissions \
    "Use the scout subagent to perform reconnaissance on this target. Repo: $TARGET_REPO, Language: $TARGET_LANG. Produce a structured recon report with: tech stack, key modules, auth mechanisms, API surface, and recommended test vectors. Output to: $SCOUT_FILE" \
    -f "$SCOUT_FILE" 2>&1 || true

  # Phase 2: Code review if scout report exists
  REVIEW_FILE="reports/codereview-${DATE}-${TARGET_NAME// /-}.md"
  echo "[agent3] Phase 2: Code review on $TARGET_NAME..."
  auto_create_task "codereview-${DATE}-${TARGET_NAME// /-}" "Code review of $TARGET_NAME" \
"### Objetivo
Clona $TARGET_REPO y realiza un code review de seguridad.
Enfoque: input parsing, auth logic, trust boundary crossings, logging de datos sensibles.
Lenguaje: $TARGET_LANG. Aplica patrones del skill correspondiente.
Output: $REVIEW_FILE"

elif [ "$OPENCODE_AVAIL" -eq 1 ]; then
  echo "[agent3] No target with score ≥70. Light day."
  case "$DOW" in
    5)
      auto_create_task "maintenance-${DATE}" "Weekly maintenance" \
"### Objetivo
1. Revisa reportes activos pendientes
2. Resume cambios semanales en bounty landscape
3. Deja brief para agent1
Output: reports/maintenance-${DATE}.md" ;;
    *) echo "[agent3] No task created." ;;
  esac
fi

# === Save agent3-latest.json ===
jq -n \
  --arg ts "$TS" \
  --arg date "$DATE" \
  --arg task "${TASK_NAME:-null}" \
  --argjson h1 $H1_COUNT \
  --argjson bc $BC_COUNT \
  --argjson it $IT_COUNT \
  --argjson yw $YWH_COUNT \
  --arg top_name "$(echo "$TOP_CANDIDATES" | jq -r '.name // "none"')" \
  --argjson top_score $TOP_SCORE \
  --argjson candidates "$(jq '.[:3] | map({name, platform, repo, language, score})' "$RANKED_FILE" 2>/dev/null || echo '[]')" \
  '{scan_date: $ts, date: $date, task: $task, platforms: {hackerone: $h1, bugcrowd: $bc, intigriti: $it, yeswehack: $yw}, top_candidate: {name: $top_name, score: $top_score}, ranked_targets: $candidates}' \
  > "memoria/agent3-latest.json"

# === Execute task ===
run_opencode_task() {
  local file="$1"
  local max_time="${2:-1200}"
  local objective
  objective=$(awk '/### Objetivo/{found=1; next} found && /^###/{exit} found' "$file" | head -30)
  [ -z "$objective" ] && echo "[agent3] No objective in $file" && return 1
  echo "[agent3] Running opencode (${max_time}s timeout)..."
  echo "[agent3] Objective: ${objective:0:120}..."
  [ -f "$file" ] && opencode run --dangerously-skip-permissions \
    "Execute this task: $objective" \
    -f "$file" 2>&1 || true
  sed -i 's/Estado: in_progress/Estado: completed/' "$file" 2>/dev/null || true
  TASKS_DONE=$((TASKS_DONE + 1))
}

if [ -n "$TASK_FILE" ] && [ "$OPENCODE_AVAIL" -eq 1 ]; then
  run_opencode_task "$TASK_FILE"
elif [ -n "$TASK_FILE" ] && [ "$OPENCODE_AVAIL" -eq 0 ]; then
  echo "[agent3] Task pending but opencode not available"
  sed -i 's/Estado: in_progress/Estado: completed/' "$TASK_FILE" 2>/dev/null || true
fi

# === Generate scanner report ===
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

## Top Candidates (scored)
$(jq -r '.[] | "\(.score) | \(.platform) | \(.name) | \(.language) | \(.stars)⭐ | \(.repo)"' "$RANKED_FILE" 2>/dev/null | head -5 | awk -F'|' '{printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6}' || echo "*No GitHub repos found in scope*")

## Target Changes
${DIFF_SECTION:-*No changes detected.*}
${QUICK_SCAN}

## Health
- Tools: gh git curl jq
- Missing: ${MISSING:-none}
- State: targets-state.json + agent3-latest.json + targets-ranked.json
REPORTEOF

# === Commit and push ===
git add reports/ memoria/ tasks/ .opencode/ setup/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.name="agent3" -c user.email="agent3@nex.local" commit -m "agent3: scan ${DATE}" 2>/dev/null || true
  git push origin main 2>/dev/null && echo "[agent3] Pushed" || echo "[agent3] Push failed"
fi

echo "[agent3] Report: $REPORT"
echo "[agent3] Top candidate: $(echo "$TOP_CANDIDATES" | jq -r '.name // "none"') (score: $TOP_SCORE/100)"

# === Self-stop ===
CS_NAME=$(gh api /user/codespaces --jq '.codespaces[] | select(.state != "Shutdown") | .name' 2>/dev/null | head -1)
if [ -n "$CS_NAME" ]; then
  echo "[agent3] Self-stopping $CS_NAME..."
  gh api -X POST "/user/codespaces/$CS_NAME/stop" > /dev/null || true
fi

echo "[agent3] Done"
exit 0
