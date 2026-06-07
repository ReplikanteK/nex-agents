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
mkdir -p reports memoria tasks/done
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
# GitHub Enrichment + Scoring Pipeline
# =====================================================================
echo "[agent3] Enriching targets with GitHub API..."

RANKED_FILE="memoria/targets-ranked.json"
SCORED_CANDIDATES="[]"
ENRICH_LOG="memoria/enrich-log-${DATE}.txt"
echo "[agent3] Enrichment log: $ENRICH_LOG" > "$ENRICH_LOG"

# Extract github.com URLs from in_scope targets
# Handles different field names per platform:
#   H1: asset_identifier, instruction | BC: target, uri | IT: endpoint, description | YWH: target
# Also handles bare domains (github.com/org/repo) and http:// URLs
extract_gh_urls() {
  local json="$1" platform="$2"
  jq -r '
    [.[] | select(.targets.in_scope != null) |
     {name: .name, url: .url,
      assets: [(.targets.in_scope[] |
        (.asset_identifier // .target // .uri // .endpoint // "") | select(length > 0)),
       (.targets.in_scope[] | .instruction // "" | select(length > 0)),
       (.targets.in_scope[] | .description // "" | select(length > 0))]}]
    | .[] | select(.assets | length > 0) |
    {name, purl: .url, assets}
  ' "$json" 2>/dev/null
}

# Categorize repo type by description and topics (0-15 pts)
# Public product=15, SDK/Lib=8, CLI=5, Infra tool=3
categorize_repo() {
  local desc="$1" topics="$2"
  [ -z "$desc" ] && [ -z "$topics" ] && echo 15 && return
  local dl=$(echo "$desc" | tr '[:upper:]' '[:lower:]')
  local tl=$(echo "$topics" | tr '[:upper:]' '[:lower:]')
  # Infrastructure/internal tool keywords
  if echo "$dl" | grep -qiE '(proxy|infrastructure|internal.*tool|sidecar|daemon|egress)'; then echo 3; return; fi
  if echo "$tl" | grep -qiE '(proxy|infrastructure|daemon)'; then echo 3; return; fi
  # CLI/Dev tool
  if echo "$dl" | grep -qiE '(cli|command.line|dev.tool)'; then echo 5; return; fi
  if echo "$tl" | grep -qiE '(cli|command-line)'; then echo 5; return; fi
  # SDK/Library/Client
  if echo "$dl" | grep -qiE '(sdk|library|client.lib|api.wrapper|toolkit)'; then echo 8; return; fi
  if echo "$tl" | grep -qiE '(sdk|library)'; then echo 8; return; fi
  # Default: public-facing product
  echo 15
}

score_target() {
  local name="$1" repo="$2" lang="$3" size="$4" stars="$5" pushed="$6" bounty="$7" surface_type="$8"
  # Pre-filter: discard if no bounty
  [ "$bounty" != "paid" ] && echo 0 && return

  # Code accessibility (0-35): language match
  local code=0
  case "$lang" in
    "Python") code=30 ;;
    "Go")     code=26 ;;
    "C"|"C++"|"Rust") code=22 ;;
    "TypeScript"|"JavaScript") code=16 ;;
    "Java")   code=12 ;;
    *)        code=8 ;;
  esac
  # Size: bonus for small, mild penalty for large
  [ "$size" -lt 10000 ] && code=$((code + 3))
  [ "$size" -gt 100000 ] && code=$((code - 3))
  [ "$size" -gt 50000 ] && [ "$size" -le 100000 ] && code=$((code - 1))
  # Stale: mild penalty (>12 months)
  local stale=$(date -d "$pushed" +%s 2>/dev/null || echo 0)
  local now=$(date +%s)
  [ $(( (now - stale) / 86400 )) -gt 365 ] && code=$((code - 2))
  [ "$code" -lt 0 ] && code=0

  # Attack surface (0-30): stars as proxy for complexity
  local surface=12
  [ "$stars" -lt 1000 ] && surface=24
  [ "$stars" -lt 500 ] && surface=27
  [ "$stars" -gt 10000 ] && surface=15

  # Likelihood (0-15): active + our languages
  local like=6
  case "$lang" in "Python"|"Go"|"C"|"C++") like=$((like + 6)) ;; esac
  [ "$size" -lt 30000 ] && like=$((like + 3))
  [ "$like" -gt 15 ] && like=15

  local total=$((code + surface + like + surface_type))
  echo "$total"
}

# Iterate over all platforms and find targets with GitHub repos
echo "[" > "$RANKED_FILE.tmp"
first=true
api_calls=0
api_ok=0
api_fail=0
github_found=0

# Repo cache: avoid re-fetching known repos across runs
REPO_CACHE="memoria/repo-cache.json"
[ -f "$REPO_CACHE" ] || echo '{}' > "$REPO_CACHE"

# Rate limit state
RATE_LIMIT_REACHED=false
RATE_LIMIT_RESET=0

for platform in hackerone bugcrowd intigriti yeswehack; do
  case "$platform" in
    hackerone) JSON="$H1_JSON"; BPLABEL="H1" ;;
    bugcrowd)  JSON="$BC_JSON"; BPLABEL="BC" ;;
    intigriti) JSON="$IT_JSON"; BPLABEL="IT" ;;
    yeswehack) JSON="$YWH_JSON"; BPLABEL="YWH" ;;
  esac
  [ ! -f "$JSON" ] && { echo "[agent3] WARN: $JSON not found, skipping $platform" >> "$ENRICH_LOG"; continue; }

  echo "[agent3] Processing $platform ($JSON)..." >> "$ENRICH_LOG"

  extract_gh_urls "$JSON" "$platform" | while read -r prog; do
    pname=$(echo "$prog" | jq -r '.name')
    purl=$(echo "$prog" | jq -r '.purl')
    assets_raw=$(echo "$prog" | jq -r '.assets[]' 2>/dev/null)
    [ -z "$assets_raw" ] && continue

    echo "$assets_raw" | while read -r asset; do
      ghurl=$(echo "$asset" | grep -ioE '(https?://)?github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_*.+-]+' 2>/dev/null || true)
      [ -z "$ghurl" ] && continue
      ghurl=$(echo "$ghurl" | sed 's|^https\?://||; s|^|https://|; s|\.git$||; s|/$||')
      owner_repo=$(echo "$ghurl" | sed 's|https://github\.com/||')
      # Skip wildcards — can't API-query github.com/org/*
      echo "$owner_repo" | grep -q '\*' && continue

      # Check cache first
      cached=$(jq -r --arg r "$owner_repo" '.[$r] // empty' "$REPO_CACHE" 2>/dev/null)
      if [ -n "$cached" ]; then
        api_ok=$((api_ok + 1))
        lang=$(echo "$cached" | jq -r '.language // "unknown"')
        size=$(echo "$cached" | jq -r '.size // 0')
        stars=$(echo "$cached" | jq -r '.stars // 0')
        pushed=$(echo "$cached" | jq -r '.pushed_at // ""')
        desc=$(echo "$cached" | jq -r '.description // ""')
        topics=$(echo "$cached" | jq -r '.topics // ""')
      else
        # Rate limit guard: check remaining calls
        if [ "$RATE_LIMIT_REACHED" = true ]; then
          echo "[agent3] SKIP $owner_repo: rate limit previously hit" >> "$ENRICH_LOG"
          continue
        fi

        api_calls=$((api_calls + 1))
        api_resp=$(curl -s -w "\n%{http_code}" -H "Authorization: token $GH_PAT" "https://api.github.com/repos/$owner_repo" 2>/dev/null)
        http_code=$(echo "$api_resp" | tail -1)
        api_resp=$(echo "$api_resp" | sed '$d')
        message=$(echo "$api_resp" | jq -r '.message // ""' 2>/dev/null)

        if [ "$http_code" = "403" ] && echo "$message" | grep -qi "rate limit"; then
          reset_ts=$(echo "$api_resp" | jq -r '.headers["x-ratelimit-reset"] // "0"' 2>/dev/null)
          echo "[agent3] RATE LIMIT HIT after $api_calls calls. Reset at: $reset_ts" | tee -a "$ENRICH_LOG"
          RATE_LIMIT_REACHED=true
          RATE_LIMIT_RESET=$reset_ts
          break 2
        fi

        if [ "$message" = "Not Found" ] || [ -z "$api_resp" ]; then
          api_fail=$((api_fail + 1))
          echo "[agent3] SKIP $owner_repo: $message" >> "$ENRICH_LOG"
          continue
        fi

        api_ok=$((api_ok + 1))
        lang=$(echo "$api_resp" | jq -r '.language // "unknown"')
        size=$(echo "$api_resp" | jq -r '.size // 0')
        stars=$(echo "$api_resp" | jq -r '.stargazers_count // 0')
        pushed=$(echo "$api_resp" | jq -r '.pushed_at // ""')
        desc=$(echo "$api_resp" | jq -r '.description // ""')
        topics=$(echo "$api_resp" | jq -r '.topics // [] | join(",")')

        # Cache this repo (skip wildcards and 404s)
        echo "$api_resp" | jq -c --arg r "$owner_repo" \
          '{($r): {language: .language, size: .size, stars: .stargazers_count, pushed_at: .pushed_at, description: .description, topics: (.topics // [] | join(","))}}' \
          > /tmp/repo-cache-entry.json 2>/dev/null
        jq -s '.[0] * .[1]' "$REPO_CACHE" /tmp/repo-cache-entry.json > /tmp/repo-cache-new.json 2>/dev/null && \
          mv /tmp/repo-cache-new.json "$REPO_CACHE"
      fi

      github_found=$((github_found + 1))

      bounty_status="paid"
      surface_type=$(categorize_repo "$desc" "$topics")
      score=$(score_target "$pname" "$ghurl" "$lang" "$size" "$stars" "$pushed" "$bounty_status" "$surface_type")

      echo "[agent3] SCORE: $pname ($BPLABEL) -> $score (lang=$lang stars=$stars surface=$surface_type)" >> "$ENRICH_LOG"

      entry="{\"name\":$(echo "$pname" | jq -Rs .),\"platform\":\"$BPLABEL\",\"url\":\"$purl\",\"repo\":\"$ghurl\",\"language\":\"$lang\",\"size_kb\":$size,\"stars\":$stars,\"pushed_at\":\"$pushed\",\"score\":$score,\"surface_type\":$surface_type,\"bounty\":\"$bounty_status\",\"scored_at\":\"$TS\"}"
      if [ "$first" = true ]; then echo "$entry" >> "$RANKED_FILE.tmp"; first=false; else echo ",$entry" >> "$RANKED_FILE.tmp"; fi
    done
  done
done
echo "]" >> "$RANKED_FILE.tmp"

echo "[agent3] Enrichment done: $api_calls API calls, $api_ok OK, $api_fail failed, $github_found repos scored (cache: $(jq 'length' "$REPO_CACHE" 2>/dev/null || echo 0) repos)" | tee -a "$ENRICH_LOG"

# Sort by score descending and take top 10
jq -s 'add | sort_by(-.score) | .[:10]' "$RANKED_FILE.tmp" 2>/dev/null > "$RANKED_FILE" || echo '[]' > "$RANKED_FILE"
rm -f "$RANKED_FILE.tmp"

TOP_CANDIDATES=$(jq -r '.[0] // empty' "$RANKED_FILE" 2>/dev/null)
TOP_SCORE=$(echo "$TOP_CANDIDATES" | jq -r '.score // 0' 2>/dev/null)
RANKED_COUNT=$(jq 'length' "$RANKED_FILE" 2>/dev/null || echo 0)

echo "[agent3] Ranked targets: $RANKED_COUNT"
echo "[agent3] Top candidate: $(echo "$TOP_CANDIDATES" | jq -r '.name // "none"') (score: $TOP_SCORE)"
echo "[agent3] Top 3:" >> "$ENRICH_LOG"
jq -r '.[:3][] | "  \(.score) \(.name) (\(.language), \(.stars) stars, \(.repo))"' "$RANKED_FILE" 2>/dev/null >> "$ENRICH_LOG"

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
# TASK SELECTION: only if candidate ≥ 65 (lowered from 70 for better coverage)
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

# Check pending backlog first (skip completed tasks and files in tasks/done/)
PENDING_TASK=$(find tasks/ -maxdepth 1 -name "*.md" ! -name "template.md" -exec grep -L 'Estado:.*completed' {} \; 2>/dev/null | head -1)
if [ -n "$PENDING_TASK" ]; then
  process_task "$PENDING_TASK"
elif [ "$TOP_SCORE" -ge 65 ] && [ "$OPENCODE_AVAIL" -eq 1 ]; then
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
  echo "[agent3] No target with score ≥65. Light day."
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

# === Save agent3-latest.json (safe: use --arg + tonumber to avoid empty var crashes) ===
TOP_NAME=$(echo "${TOP_CANDIDATES:-}" | jq -r '.name // ""' 2>/dev/null || echo "")
RANKED_JSON=$(jq '.[:3] | map({name, platform, repo, language, score})' "${RANKED_FILE:-memoria/targets-ranked.json}" 2>/dev/null || echo '[]')
jq -n \
  --arg ts "$TS" \
  --arg date "$DATE" \
  --arg task "${TASK_NAME:-}" \
  --arg h1 "${H1_COUNT:-0}" \
  --arg bc "${BC_COUNT:-0}" \
  --arg it "${IT_COUNT:-0}" \
  --arg yw "${YWH_COUNT:-0}" \
  --arg top_name "$TOP_NAME" \
  --arg top_score "${TOP_SCORE:-0}" \
  --argjson candidates "$RANKED_JSON" \
  '{scan_date: $ts, date: $date, task: $task, platforms: {hackerone: ($h1|tonumber), bugcrowd: ($bc|tonumber), intigriti: ($it|tonumber), yeswehack: ($yw|tonumber)}, top_candidate: {name: $top_name, score: ($top_score|tonumber)}, ranked_targets: $candidates}' \
  > "memoria/agent3-latest.json" 2>/dev/null || echo "{\"error\":\"generation_failed\",\"date\":\"$DATE\"}" > "memoria/agent3-latest.json"

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
  mv "$file" tasks/done/ 2>/dev/null || true
  TASKS_DONE=$((TASKS_DONE + 1))
}

if [ -n "$TASK_FILE" ] && [ "$OPENCODE_AVAIL" -eq 1 ]; then
  run_opencode_task "$TASK_FILE"
elif [ -n "$TASK_FILE" ] && [ "$OPENCODE_AVAIL" -eq 0 ]; then
  echo "[agent3] Task pending but opencode not available"
  sed -i 's/Estado: in_progress/Estado: completed/' "$TASK_FILE" 2>/dev/null || true
  mv "$TASK_FILE" tasks/done/ 2>/dev/null || true
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
| Score | Platform | Target | Lang | Stars | Surface | Repo |
|-------|----------|--------|------|-------|---------|------|
$(jq -r '.[] | "\(.score) | \(.platform) | \(.name) | \(.language) | \(.stars) | \(.surface_type) | \(.repo)"' "$RANKED_FILE" 2>/dev/null | head -5 | while IFS='|' read -r score plat name lang stars stype repo; do stype_label="prod"; [ "$stype" = "3" ] && stype_label="infra"; [ "$stype" = "5" ] && stype_label="cli"; [ "$stype" = "8" ] && stype_label="sdk"; printf "| %s | %s | %s | %s | %s⭐ | %s | %s |\n" "$score" "$plat" "$name" "$lang" "$stars" "$stype_label" "$repo"; done || echo "*No GitHub repos found in scope*")

## Target Changes
${DIFF_SECTION:-*No changes detected.*}
${QUICK_SCAN}

## Health
- Tools: gh git curl jq
- Missing: ${MISSING:-none}
- State: targets-state.json + agent3-latest.json + targets-ranked.json

## Enrichment Details
$(cat "$ENRICH_LOG" 2>/dev/null || echo "*No enrichment log*")
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
