#!/usr/bin/env bash
set -uo pipefail

# enrich.sh - Run on ubuntu-latest (FREE)
# Fetches bounty data, does GitHub API enrichment, produces ranked targets
# Output: memoria/targets-ranked.json, memoria/agent3-latest.json

GH_PAT="${1:-${GITHUB_TOKEN:-}}"
[ -z "$GH_PAT" ] && echo "[enrich] No token" && exit 1
export GH_TOKEN="$GH_PAT"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DATE=$(date +%Y-%m-%d)
DOW=$(date +%u)
echo "[enrich] $TS - Enrichment starting... (day $DOW)"

# === Health check ===
for cmd in gh git curl jq; do
  command -v "$cmd" &>/dev/null || { echo "[enrich] Missing: $cmd"; exit 1; }
done

# === Clone repo ===
REPO_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$REPO_DIR" || exit 1
gh auth setup-git 2>/dev/null || true
git pull origin main 2>/dev/null || true

# === Fetch bounty data ===
BOUNTY_DIR="/tmp/bounty-targets-data"
if [ ! -d "$BOUNTY_DIR/.git" ]; then
  git clone --depth 1 https://github.com/arkadiyt/bounty-targets-data.git "$BOUNTY_DIR" 2>/dev/null || true
else
  git -C "$BOUNTY_DIR" pull origin master 2>/dev/null || true
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

# Diff logic
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
    DIFF_SECTION="${DIFF_SECTION}### ${label}\n"
    [ -n "$new_str" ] && DIFF_SECTION="${DIFF_SECTION}**New ($(echo "$new_str" | wc -l):**\n\`\`\`\n$new_str\n\`\`\`\n"
    [ -n "$rem_str" ] && DIFF_SECTION="${DIFF_SECTION}**Removed ($(echo "$rem_str" | wc -l):**\n\`\`\`\n$rem_str\n\`\`\`\n"
  fi
}
diff_platform "HackerOne" "$H1_NOW" "$H1_PREV"
diff_platform "Bugcrowd" "$BC_NOW" "$BC_PREV"
diff_platform "Intigriti" "$IT_NOW" "$IT_PREV"
diff_platform "YesWeHack" "$YWH_NOW" "$YWH_PREV"

# Save full state
write_platform() { jq '[.[] | {name, url}]' "$1" 2>/dev/null || echo '[]'; }
jq -n --arg ts "$TS" --argjson h1 "$(write_platform "$H1_JSON")" --argjson bc "$(write_platform "$BC_JSON")" --argjson it "$(write_platform "$IT_JSON")" --argjson yw "$(write_platform "$YWH_JSON")" '{last_scan: $ts, targets: {hackerone: $h1, bugcrowd: $bc, intigriti: $it, yeswehack: $yw}}' > "$STATE_FILE"

# =====================================================================
# GitHub Enrichment + Scoring Pipeline
# =====================================================================
echo "[enrich] Enriching targets with GitHub API..."

RANKED_FILE="memoria/targets-ranked.json"
SCORED_CANDIDATES="[]"
ENRICH_LOG="memoria/enrich-log-${DATE}.txt"
echo "[enrich] Enrichment log: $ENRICH_LOG" > "$ENRICH_LOG"

# Extract github.com URLs from in_scope targets
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
categorize_repo() {
  local desc="$1" topics="$2"
  [ -z "$desc" ] && [ -z "$topics" ] && echo 15 && return
  local dl=$(echo "$desc" | tr '[:upper:]' '[:lower:]')
  local tl=$(echo "$topics" | tr '[:upper:]' '[:lower:]')
  if echo "$dl" | grep -qiE '(proxy|infrastructure|internal.*tool|sidecar|daemon|egress)'; then echo 3; return; fi
  if echo "$tl" | grep -qiE '(proxy|infrastructure|daemon)'; then echo 3; return; fi
  if echo "$dl" | grep -qiE '(cli|command.line|dev.tool)'; then echo 5; return; fi
  if echo "$tl" | grep -qiE '(cli|command-line)'; then echo 5; return; fi
  if echo "$dl" | grep -qiE '(sdk|library|client.lib|api.wrapper|toolkit)'; then echo 8; return; fi
  if echo "$tl" | grep -qiE '(sdk|library)'; then echo 8; return; fi
  echo 15
}

score_target() {
  local name="$1" repo="$2" lang="$3" size="$4" stars="$5" pushed="$6" bounty="$7" surface_type="$8"
  [ "$bounty" != "paid" ] && echo 0 && return

  local code=0
  case "$lang" in
    "Python") code=30 ;;
    "Go")     code=26 ;;
    "C"|"C++"|"Rust") code=22 ;;
    "TypeScript"|"JavaScript") code=16 ;;
    "Java")   code=12 ;;
    *)        code=8 ;;
  esac
  [ "$size" -lt 10000 ] && code=$((code + 3))
  [ "$size" -gt 100000 ] && code=$((code - 3))
  [ "$size" -gt 50000 ] && [ "$size" -le 100000 ] && code=$((code - 1))
  local stale=$(date -d "$pushed" +%s 2>/dev/null || echo 0)
  local now=$(date +%s)
  [ $(( (now - stale) / 86400 )) -gt 365 ] && code=$((code - 2))
  [ "$code" -lt 0 ] && code=0

  local surface=12
  [ "$stars" -lt 1000 ] && surface=24
  [ "$stars" -lt 500 ] && surface=27
  [ "$stars" -gt 10000 ] && surface=15

  local like=6
  case "$lang" in "Python"|"Go"|"C"|"C++") like=$((like + 6)) ;; esac
  [ "$size" -lt 30000 ] && like=$((like + 3))
  [ "$like" -gt 15 ] && like=15

  local total=$((code + surface + like + surface_type))
  echo "$total"
}

# Batch API calls using xargs for parallelism
echo "[enrich] Starting parallel enrichment..."

# First, collect all unique repos
ALL_REPOS_FILE="/tmp/all-repos.txt"
> "$ALL_REPOS_FILE"

for platform in hackerone bugcrowd intigriti yeswehack; do
  case "$platform" in
    hackerone) JSON="$H1_JSON"; BPLABEL="H1" ;;
    bugcrowd)  JSON="$BC_JSON"; BPLABEL="BC" ;;
    intigriti) JSON="$IT_JSON"; BPLABEL="IT" ;;
    yeswehack) JSON="$YWH_JSON"; BPLABEL="YWH" ;;
  esac
  [ ! -f "$JSON" ] && continue

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
      echo "$owner_repo" | grep -q '\*' && continue
      echo "$BPLABEL|$pname|$purl|$owner_repo" >> "$ALL_REPOS_FILE"
    done
  done
done

# Deduplicate repos (same repo can appear in multiple programs)
UNIQUE_REPOS_FILE="/tmp/unique-repos.txt"
awk -F'|' '{print $4}' "$ALL_REPOS_FILE" | sort -u > "$UNIQUE_REPOS_FILE"
TOTAL_REPOS=$(wc -l < "$UNIQUE_REPOS_FILE")
echo "[enrich] Found $TOTAL_REPOS unique repos to enrich"

# Repo cache
REPO_CACHE="memoria/repo-cache.json"
[ -f "$REPO_CACHE" ] || echo '{}' > "$REPO_CACHE"

# Batch fetch function
fetch_repo_batch() {
  local batch_file="$1"
  local batch_num="$2"
  
  while read -r owner_repo; do
    # Check cache first
    cached=$(jq -r --arg r "$owner_repo" '.[$r] // empty' "$REPO_CACHE" 2>/dev/null)
    if [ -n "$cached" ]; then
      echo "CACHED|$owner_repo|$cached"
      continue
    fi
    
    # API call
    api_resp=$(curl -s -w "\n%{http_code}" -H "Authorization: token $GH_PAT" "https://api.github.com/repos/$owner_repo" 2>/dev/null)
    http_code=$(echo "$api_resp" | tail -1)
    api_resp=$(echo "$api_resp" | sed '$d')
    message=$(echo "$api_resp" | jq -r '.message // ""' 2>/dev/null)
    
    if [ "$http_code" = "403" ] && echo "$message" | grep -qi "rate limit"; then
      echo "RATE_LIMIT|$owner_repo"
      break
    fi
    
    if [ "$message" = "Not Found" ] || [ -z "$api_resp" ]; then
      echo "404|$owner_repo"
      continue
    fi
    
    # Parse response
    lang=$(echo "$api_resp" | jq -r '.language // "unknown"')
    size=$(echo "$api_resp" | jq -r '.size // 0')
    stars=$(echo "$api_resp" | jq -r '.stargazers_count // 0')
    pushed=$(echo "$api_resp" | jq -r '.pushed_at // ""')
    desc=$(echo "$api_resp" | jq -r '.description // ""')
    topics=$(echo "$api_resp" | jq -r '.topics // [] | join(",")')
    
    # Cache
    echo "$api_resp" | jq -c --arg r "$owner_repo" \
      '{($r): {language: .language, size: .size, stars: .stargazers_count, pushed_at: .pushed_at, description: .description, topics: (.topics // [] | join(","))}}' \
      > /tmp/repo-cache-entry.json 2>/dev/null
    jq -s '.[0] * .[1]' "$REPO_CACHE" /tmp/repo-cache-entry.json > /tmp/repo-cache-new.json 2>/dev/null && \
      mv /tmp/repo-cache-new.json "$REPO_CACHE"
    
    echo "OK|$owner_repo|$lang|$size|$stars|$pushed|$desc|$topics"
  done < "$batch_file"
}

# Split into batches of 50 for parallel processing
BATCH_SIZE=50
BATCH_NUM=0
RESULTS_FILE="/tmp/enrich-results.txt"
> "$RESULTS_FILE"

split -l "$BATCH_SIZE" "$UNIQUE_REPOS_FILE" /tmp/batch-
for batch_file in /tmp/batch-*; do
  [ ! -f "$batch_file" ] && continue
  BATCH_NUM=$((BATCH_NUM + 1))
  echo "[enrich] Processing batch $BATCH_NUM..."
  fetch_repo_batch "$batch_file" "$BATCH_NUM" >> "$RESULTS_FILE" 2>/dev/null
done
rm -f /tmp/batch-*

# Score candidates
echo "[enrich] Scoring candidates..."
echo "[" > "$RANKED_FILE.tmp"
first=true

while IFS='|' read -r owner_repo; do
  result=$(grep "^OK|$owner_repo|" "$RESULTS_FILE" | head -1)
  [ -z "$result" ] && continue
  
  IFS='|' read -r _ repo lang size stars pushed desc topics <<< "$result"
  
  # Find all programs that reference this repo
  programs=$(grep "|$owner_repo$" "$ALL_REPOS_FILE" | awk -F'|' '{print $1 "|" $2 "|" $3}' | sort -u)
  
  while IFS='|' read -r platform pname purl; do
    bounty_status="paid"
    surface_type=$(categorize_repo "$desc" "$topics")
    score=$(score_target "$pname" "https://github.com/$owner_repo" "$lang" "$size" "$stars" "$pushed" "$bounty_status" "$surface_type")
    
    [ "$score" -eq 0 ] && continue
    
    echo "[enrich] SCORE: $pname ($platform) -> $score (lang=$lang stars=$stars)" >> "$ENRICH_LOG"
    
    entry="{\"name\":$(echo "$pname" | jq -Rs .),\"platform\":\"$platform\",\"url\":\"$purl\",\"repo\":\"https://github.com/$owner_repo\",\"language\":\"$lang\",\"size_kb\":$size,\"stars\":$stars,\"pushed_at\":\"$pushed\",\"score\":$score,\"surface_type\":$surface_type,\"bounty\":\"$bounty_status\",\"scored_at\":\"$TS\"}"
    if [ "$first" = true ]; then echo "$entry" >> "$RANKED_FILE.tmp"; first=false; else echo ",$entry" >> "$RANKED_FILE.tmp"; fi
  done <<< "$programs"
done < "$UNIQUE_REPOS_FILE"

echo "]" >> "$RANKED_FILE.tmp"
jq -s 'add | sort_by(-.score) | .[:10]' "$RANKED_FILE.tmp" 2>/dev/null > "$RANKED_FILE" || echo '[]' > "$RANKED_FILE"
rm -f "$RANKED_FILE.tmp"

echo "[enrich] Enrichment done: $TOTAL_REPOS repos processed"

TOP_CANDIDATES=$(jq -r '.[0] // empty' "$RANKED_FILE" 2>/dev/null)
TOP_SCORE=$(echo "$TOP_CANDIDATES" | jq -r '.score // 0' 2>/dev/null)
RANKED_COUNT=$(jq 'length' "$RANKED_FILE" 2>/dev/null || echo 0)

echo "[enrich] Ranked targets: $RANKED_COUNT"
echo "[enrich] Top candidate: $(echo "$TOP_CANDIDATES" | jq -r '.name // "none"') (score: $TOP_SCORE)"

# === Save agent3-latest.json ===
TOP_NAME=$(echo "${TOP_CANDIDATES:-}" | jq -r '.name // ""' 2>/dev/null || echo "")
RANKED_JSON=$(jq '.[:3] | map({name, platform, repo, language, score})' "${RANKED_FILE}" 2>/dev/null || echo '[]')
jq -n \
  --arg ts "$TS" \
  --arg date "$DATE" \
  --arg task "" \
  --arg h1 "${H1_COUNT:-0}" \
  --arg bc "${BC_COUNT:-0}" \
  --arg it "${IT_COUNT:-0}" \
  --arg yw "${YWH_COUNT:-0}" \
  --arg top_name "$TOP_NAME" \
  --arg top_score "${TOP_SCORE:-0}" \
  --argjson candidates "$RANKED_JSON" \
  '{scan_date: $ts, date: $date, task: $task, platforms: {hackerone: ($h1|tonumber), bugcrowd: ($bc|tonumber), intigriti: ($it|tonumber), yeswehack: ($yw|tonumber)}, top_candidate: {name: $top_name, score: ($top_score|tonumber)}, ranked_targets: $candidates}' \
  > "memoria/agent3-latest.json" 2>/dev/null || echo "{\"error\":\"generation_failed\",\"date\":\"$DATE\"}" > "memoria/agent3-latest.json"

# === Quick-scan new targets ===
ALL_NOW=$( (echo "$H1_NOW"; echo "$BC_NOW"; echo "$IT_NOW"; echo "$YWH_NOW") | sort -u)
ALL_PREV=$( (echo "${H1_PREV:-}"; echo "${BC_PREV:-}"; echo "${IT_PREV:-}"; echo "${YWH_PREV:-}") | sort -u)
BRAND_NEW=$(comm -23 <(echo "$ALL_NOW") <(echo "$ALL_PREV") 2>/dev/null | head -5)
QUICK_SCAN=""
if [ -n "$BRAND_NEW" ] && command -v curl &>/dev/null; then
  echo "[enrich] Quick-scanning new targets..."
  QUICK_SCAN="## Quick Scan (new targets)\n| Target | URL | HTTP |\n|--------|-----|------|\n"
  while IFS='|' read -r name url; do
    [ -z "$name" ] && continue
    http=$(curl -sI -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 5 "$url" 2>/dev/null || echo "ERR")
    QUICK_SCAN="${QUICK_SCAN}| $name | $url | $http |\n"
  done <<< "$BRAND_NEW"
fi

# === Generate scanner report ===
REPORT="reports/scanner-${DATE}.md"
cat > "$REPORT" << REPORTEOF
# Scanner Report - ${DATE}
- Generated: $TS
- Enrichment: ubuntu-latest (free)
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

## Enrichment Details
$(cat "$ENRICH_LOG" 2>/dev/null || echo "*No enrichment log*")
REPORTEOF

# === Commit and push ===
git add reports/ memoria/ tasks/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.name="enrich-bot" -c user.email="enrich@nex.local" commit -m "enrich: scan ${DATE}" 2>/dev/null || true
  git push origin main 2>/dev/null && echo "[enrich] Pushed" || echo "[enrich] Push failed"
fi

echo "[enrich] Done"
echo "[enrich] Top candidate: $(echo "$TOP_CANDIDATES" | jq -r '.name // "none"') (score: $TOP_SCORE/100)"
exit 0
