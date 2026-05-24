#!/usr/bin/env bash
set -uo pipefail

GH_PAT="${1:-${GITHUB_TOKEN:-}}"
[ -z "$GH_PAT" ] && echo "[agent3] No token" && exit 1
export GH_TOKEN="$GH_PAT"
export GIT_TERMINAL_PROMPT=0
export PATH="$HOME/.opencode/bin:$PATH"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DATE=$(date +%Y-%m-%d)
echo "[agent3] $TS - Scan starting..."

# === Health ===
MISSING=""
for cmd in gh git curl jq; do
  command -v "$cmd" &>/dev/null || { MISSING="$MISSING $cmd"; }
done

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

# === Task ===
TASK_NAME=""
TASK_FILE=$(find tasks/ -maxdepth 1 -name "*.md" ! -name "template.md" 2>/dev/null | head -1)
if [ -n "$TASK_FILE" ]; then
  TASK_NAME=$(basename "$TASK_FILE" .md)
  sed -i 's/Estado: pending/Estado: in_progress/' "$TASK_FILE" 2>/dev/null || true
fi

# === Fetch bounty data ===
BOUNTY_DIR="/tmp/bounty-targets-data"
echo "[agent3] Fetching bounty data..."
if command -v git &>/dev/null; then
  if [ ! -d "$BOUNTY_DIR/.git" ]; then
    git clone --depth 1 https://github.com/arkadiyt/bounty-targets-data.git "$BOUNTY_DIR" 2>/dev/null || echo "[agent3] clone failed"
  else
    git -C "$BOUNTY_DIR" pull origin master 2>/dev/null || true
  fi
fi

# === Diff engine ===
mkdir -p reports memoria
STATE_FILE="memoria/targets-state.json"

# Current: extract names per platform (sorted, deduped)
get_names() { jq -r '.[].name // empty' "$1" 2>/dev/null | sort -u; }
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

# Previous state
if [ -f "$STATE_FILE" ]; then
  H1_PREV=$(jq -r '.targets.hackerone[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
  BC_PREV=$(jq -r '.targets.bugcrowd[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
  IT_PREV=$(jq -r '.targets.intigriti[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
  YWH_PREV=$(jq -r '.targets.yeswehack[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
else
  H1_PREV=""; BC_PREV=""; IT_PREV=""; YWH_PREV=""
fi

# Diff
DIFF_SECTION=""
diff_platform() {
  local label="$1" now="$2" prev="$3"
  local new_str="" rem_str=""
  if [ -n "$prev" ]; then
    new_str=$(comm -23 <(echo "$now") <(echo "$prev") 2>/dev/null | head -10)
    rem_str=$(comm -13 <(echo "$now") <(echo "$prev") 2>/dev/null | head -10)
  else
    new_str=$(echo "$now" | head -10)
    rem_str=""
  fi
  if [ -n "$new_str" ] || [ -n "$rem_str" ]; then
    DIFF_SECTION+="### $label\n"
    [ -n "$new_str" ] && DIFF_SECTION+="\n**New ($(echo "$new_str" | wc -l)):**\n\`\`\`\n$new_str\n\`\`\`\n"
    [ -n "$rem_str" ] && DIFF_SECTION+="\n**Removed ($(echo "$rem_str" | wc -l)):**\n\`\`\`\n$rem_str\n\`\`\`\n"
  fi
}

diff_platform "HackerOne" "$H1_NOW" "$H1_PREV"
diff_platform "Bugcrowd" "$BC_NOW" "$BC_PREV"
diff_platform "Intigriti" "$IT_NOW" "$IT_PREV"
diff_platform "YesWeHack" "$YWH_NOW" "$YWH_PREV"

# === Quick-scan new targets (liveness) ===
ALL_NOW=$( (echo "$H1_NOW"; echo "$BC_NOW"; echo "$IT_NOW"; echo "$YWH_NOW") | sort -u )
ALL_PREV=$( (echo "${H1_PREV:-}"; echo "${BC_PREV:-}"; echo "${IT_PREV:-}"; echo "${YWH_PREV:-}") | sort -u )
BRAND_NEW=$(comm -23 <(echo "$ALL_NOW") <(echo "$ALL_PREV") 2>/dev/null | head -5)

QUICK_SCAN=""
if [ -n "$BRAND_NEW" ] && command -v curl &>/dev/null; then
  echo "[agent3] Quick-scanning new targets..."
  QUICK_SCAN="## Quick Scan (new targets)\n| Target | URL | HTTP |\n|--------|-----|------|\n"
  while IFS='|' read -r name url; do
    [ -z "$name" ] && continue
    http=$(curl -sI -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 5 "$url" 2>/dev/null || echo "ERR")
    QUICK_SCAN+="| $name | $url | $http |\n"
  done <<< "$BRAND_NEW"
fi

# === Save current state as JSON ===
echo "[agent3] Saving state..."
if command -v jq &>/dev/null; then
  write_platform() {
    local file="$1"
    jq '[.[] | {name, url}]' "$file" 2>/dev/null || echo '[]'
  }
  jq -n \
    --arg ts "$TS" \
    --argjson h1 "$(write_platform "$H1_JSON")" \
    --argjson bc "$(write_platform "$BC_JSON")" \
    --argjson it "$(write_platform "$IT_JSON")" \
    --argjson yw "$(write_platform "$YWH_JSON")" \
    '{last_scan: $ts, targets: {hackerone: $h1, bugcrowd: $bc, intigriti: $it, yeswehack: $yw}}' \
    > "$STATE_FILE"
fi

# === Write JSON report for agent1 ===
AGENT1_JSON="memoria/agent3-latest.json"
{
  echo "{"
  echo "  \"scan_date\": \"$TS\","
  echo "  \"date\": \"$DATE\","
  echo "  \"task\": \"${TASK_NAME:-null}\","
  echo "  \"platforms\": {"
  echo "    \"hackerone\": $H1_COUNT,"
  echo "    \"bugcrowd\": $BC_COUNT,"
  echo "    \"intigriti\": $IT_COUNT,"
  echo "    \"yeswehack\": $YWH_COUNT"
  echo "  }"
  echo "}"
} > "$AGENT1_JSON"

# === Generate markdown report ===
REPORT="reports/scanner-${DATE}.md"
cat > "$REPORT" << REPORTEOF
# Scanner Report - ${DATE}
- Generated: $TS
- Task: ${TASK_NAME:-none}
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

# === Run daily scanner if available ===
if [ -f "setup/daily-scanner.sh" ]; then
  echo "[agent3] Running daily scanner..."
  bash setup/daily-scanner.sh || true
fi

# === Commit and push ===
git add reports/ memoria/ tasks/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.name="agent3" -c user.email="agent3@nex.local" commit -m "agent3: scan ${DATE}" 2>/dev/null || true
  git push origin main 2>/dev/null && echo "[agent3] Pushed" || echo "[agent3] Push failed"
fi

echo "[agent3] Report: $REPORT"
echo "[agent3] State: $STATE_FILE"
echo "[agent3] Agent1 JSON: $AGENT1_JSON"

# === Self-stop ===
CS_NAME=$(gh api /user/codespaces --jq '.codespaces[] | select(.state != "Shutdown") | .name' 2>/dev/null | head -1)
if [ -n "$CS_NAME" ]; then
  echo "[agent3] Self-stopping $CS_NAME..."
  gh api -X POST "/user/codespaces/$CS_NAME/stop" > /dev/null || true
fi

echo "[agent3] Done"
exit 0
