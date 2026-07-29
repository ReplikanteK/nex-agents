#!/usr/bin/env bash
set -uo pipefail

# enrich.sh - Personalized enrichment pipeline
# Runs on ubuntu-latest (FREE)
# Output: memoria/agent3-latest.json, memoria/targets-ranked.json

export PATH="/tmp:$PATH"

GH_PAT="${1:-${GITHUB_TOKEN:-}}"
[ -z "$GH_PAT" ] && echo "[enrich] No token" && exit 1
export GH_TOKEN="$GH_PAT"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DATE=$(date +%Y-%m-%d)
DOW=$(date +%u)
echo "[enrich] $TS - Personalized enrichment starting... (day $DOW)"

for cmd in gh git curl jq; do
  command -v "$cmd" &>/dev/null || { echo "[enrich] Missing: $cmd"; exit 1; }
done

echo "[enrich] Validating GitHub token..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $GH_PAT" "https://api.github.com/user" 2>/dev/null)
if [ "$HTTP_CODE" != "200" ]; then
  echo "[enrich] ERROR: Invalid token (HTTP $HTTP_CODE)"
  exit 1
fi
echo "[enrich] Token valid"

RATE_REMAINING=$(curl -s -H "Authorization: token $GH_PAT" "https://api.github.com/rate_limit" 2>/dev/null | jq -r '.rate.remaining // 0' 2>/dev/null)
echo "[enrich] GitHub API rate limit: $RATE_REMAINING remaining"
[ "$RATE_REMAINING" -lt 50 ] && echo "[enrich] WARNING: Very low rate limit"

REPO_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$REPO_DIR" || exit 1
gh auth setup-git 2>/dev/null || true
git pull origin main 2>/dev/null || true

K_PROFILE="memoria/k-profile.json"
if [ ! -f "$K_PROFILE" ]; then
  echo "[enrich] ERROR: K-profile not found"
  exit 1
fi
echo "[enrich] K-profile loaded"

BOUNTY_DIR="/tmp/bounty-targets-data"
if [ ! -d "$BOUNTY_DIR/.git" ]; then
  echo "[enrich] Cloning bounty-targets-data..."
  git clone --depth 1 https://github.com/arkadiyt/bounty-targets-data.git "$BOUNTY_DIR" 2>&1 | tail -3
else
  git -C "$BOUNTY_DIR" pull origin master 2>&1 | tail -3
fi

if [ ! -f "$BOUNTY_DIR/data/hackerone_data.json" ]; then
  echo "[enrich] ERROR: bounty-targets-data not found"
  exit 1
fi

mkdir -p reports memoria tasks/done

H1_JSON="$BOUNTY_DIR/data/hackerone_data.json"
BC_JSON="$BOUNTY_DIR/data/bugcrowd_data.json"
IT_JSON="$BOUNTY_DIR/data/intigriti_data.json"
YWH_JSON="$BOUNTY_DIR/data/yeswehack_data.json"

count_targets() {
  [ ! -f "$1" ] && echo "0" && return
  jq '[.[] | select(.targets.in_scope != null)] | length' "$1" 2>/dev/null || echo "0"
}

H1_COUNT=$(count_targets "$H1_JSON")
BC_COUNT=$(count_targets "$BC_JSON")
IT_COUNT=$(count_targets "$IT_JSON")
YWH_COUNT=$(count_targets "$YWH_JSON")
echo "[enrich] Targets: H1=$H1_COUNT BC=$BC_COUNT IT=$IT_COUNT YWH=$YWH_COUNT"

detect_language() {
  local urls="$1"
  local first_url
  first_url=$(echo "$urls" | jq -r '.[0] // empty' 2>/dev/null)
  [ -z "$first_url" ] && echo "unknown" && return
  local repo_path
  repo_path=$(echo "$first_url" | grep -oP 'github\.com/\K[A-Za-z0-9_.-]+/[A-Za-z0-9_*.+-]+' | head -1)
  [ -z "$repo_path" ] && echo "unknown" && return
  local cache_file="/tmp/lang-${repo_path//\//_}"
  if [ -f "$cache_file" ]; then cat "$cache_file"; return; fi
  local lang
  lang=$(curl -sf -H "Authorization: token $GH_PAT" "https://api.github.com/repos/$repo_path" 2>/dev/null | jq -r '.language // "unknown"' 2>/dev/null)
  [ -z "$lang" ] || [ "$lang" = "null" ] && lang="unknown"
  echo "$lang" > "$cache_file"
  echo "$lang"
}

map_language() {
  case "$1" in
    Python) echo "python" ;; Go) echo "go" ;; Rust) echo "rust" ;;
    C) echo "c_cpp" ;; "C++") echo "c_cpp" ;;
    JavaScript) echo "javascript_typescript" ;; TypeScript) echo "javascript_typescript" ;;
    Java) echo "java" ;; *) echo "unknown" ;;
  esac
}

echo "[enrich] Step 1: Extracting programs..."
ALL_PROGRAMS_FILE="/tmp/all-programs.json"
> "$ALL_PROGRAMS_FILE"

for platform_data in "hackerone:$H1_JSON:H1" "bugcrowd:$BC_JSON:BC" "intigriti:$IT_JSON:IT" "yeswehack:$YWH_JSON:YWH"; do
  IFS=':' read -r platform json_file label <<< "$platform_data"
  [ ! -f "$json_file" ] && { echo "[enrich] SKIP: $label"; continue; }
  echo "[enrich] Extracting from $label..."
  jq -rc --arg platform "$platform" '
    [.[] | select(.targets.in_scope != null) |
     {name: .name, url: .url, platform: $platform,
      offers_bounties: (.offers_bounties // false),
      managed: (.managed_program // .managed_by_bugcrowd // false),
      max_bounty: (if (.max_bounty | type) == "object" then .max_bounty.value else .max_bounty end),
      assets_count: ([.targets.in_scope[] | select(.eligible_for_bounty == true or .eligible_for_bounty == null)] | length),
      github_urls: [.targets.in_scope[] |
        (.asset_identifier // .target // .uri // .endpoint // "") |
        select(length > 0 and test("github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_*.+-]+"))]}]
    | .[] | {name, url, platform, offers_bounties, managed, max_bounty, assets_count, github_urls}
  ' "$json_file" 2>/dev/null | while IFS= read -r prog; do
    [ -n "$prog" ] && echo "$prog" >> "$ALL_PROGRAMS_FILE"
  done
done

TOTAL_PROGRAMS=$(wc -l < "$ALL_PROGRAMS_FILE" 2>/dev/null || echo 0)
echo "[enrich] Total: $TOTAL_PROGRAMS"

if [ "$TOTAL_PROGRAMS" -eq 0 ]; then
  echo "[enrich] ERROR: No programs extracted"
  jq -n --arg ts "$TS" --arg date "$DATE" \
    '{scan_date: $ts, date: $date, stats: {filtered: 0, scored: 0, selected: 0}, top_candidate: {name: "", score: 0}, ranked_targets: [], selected_targets: []}' \
    > "memoria/agent3-latest.json"
  exit 0
fi

echo "[enrich] Step 2: Filtering..."
FILTERED_FILE="/tmp/filtered-programs.json"
> "$FILTERED_FILE"

while IFS= read -r prog; do
  [ -z "$prog" ] && continue
  name=$(echo "$prog" | jq -r '.name // ""')
  platform=$(echo "$prog" | jq -r '.platform // ""')
  max_bounty=$(echo "$prog" | jq -r '.max_bounty // "null"')
  assets_count=$(echo "$prog" | jq -r '.assets_count // 0')
  passed="true"
  reject_reason=""
  name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')

  if echo "$name_lower" | grep -qiE '(government|military|gov\.|army|navy|police|defense)'; then
    passed="false"; reject_reason="government"
  fi
  if [ "$passed" = "true" ]; then
    can_submit=$(jq -r --arg p "$platform" '.track_record.platform_status[$p].can_submit // false' "$K_PROFILE" 2>/dev/null)
    if [ "$can_submit" != "true" ]; then
      passed="false"; reject_reason="platform_unavailable($platform)"
    fi
  fi
  if [ "$passed" = "true" ] && [ "$max_bounty" != "null" ] && [ "$max_bounty" != "0" ] && [ "$max_bounty" != "" ]; then
    min_req=$(jq -r '.preferences.min_bounty_usd // 500' "$K_PROFILE" 2>/dev/null)
    if echo "$max_bounty" | grep -qP '^\d+$'; then
      if [ "$max_bounty" -lt "$min_req" ] 2>/dev/null; then
        passed="false"; reject_reason="bounty_low($max_bounty<$min_req)"
      fi
    fi
  fi
  if [ "$passed" = "true" ]; then
    if echo "$name_lower" | grep -qiE '(lightspark|uber|airbnb|shopify|gitlab)'; then
      passed="false"; reject_reason="saturated"
    fi
  fi
  if [ "$passed" = "true" ] && [ "$assets_count" -eq 0 ] 2>/dev/null; then
    passed="false"; reject_reason="no_assets"
  fi
  if [ "$passed" = "true" ]; then
    echo "$prog" >> "$FILTERED_FILE"
  fi
done < "$ALL_PROGRAMS_FILE"

FILTERED_COUNT=$(wc -l < "$FILTERED_FILE" 2>/dev/null || echo 0)
echo "[enrich] After filter: $FILTERED_COUNT"

if [ "$FILTERED_COUNT" -eq 0 ]; then
  echo "[enrich] All filtered out"
  jq -n --arg ts "$TS" --arg date "$DATE" \
    --argjson h1 "$H1_COUNT" --argjson bc "$BC_COUNT" --argjson it "$IT_COUNT" --argjson yw "$YWH_COUNT" \
    '{scan_date: $ts, date: $date, platforms: {hackerone: $h1, bugcrowd: $bc, intigriti: $it, yeswehack: $yw}, stats: {filtered: 0, scored: 0, selected: 0}, top_candidate: {name: "", score: 0}, ranked_targets: [], selected_targets: []}' \
    > "memoria/agent3-latest.json"
  exit 0
fi

echo "[enrich] Step 3: Scoring..."
SCORED_FILE="/tmp/scored-programs.json"
> "$SCORED_FILE"

echo "[enrich] Checking for previous execute failures (last 7 days)..."
SINCE=$(date -d "7 days ago" +%Y-%m-%d)
FAILURE_ISSUES=$(gh issue list --repo "ReplikanteK/nex-agents" --state open --search "created:>=$SINCE Execute Failure" --json title 2>/dev/null | jq -r '.[].title' 2>/dev/null || echo "")

while IFS= read -r prog; do
  [ -z "$prog" ] && continue
  name=$(echo "$prog" | jq -r '.name // ""')
  platform=$(echo "$prog" | jq -r '.platform // ""')
  max_bounty=$(echo "$prog" | jq -r '.max_bounty // "null"')
  assets_count=$(echo "$prog" | jq -r '.assets_count // 0')
  github_urls=$(echo "$prog" | jq -c '.github_urls // []' 2>/dev/null)
  has_github=$(echo "$prog" | jq -r '(.github_urls | length) > 0' 2>/dev/null)

  language="unknown"
  if [ "$has_github" = "true" ]; then
    language=$(detect_language "$github_urls")
  fi
  lang_key=$(map_language "$language")

  # FIT (0-30)
  fit_score=0
  lang_weight=$(jq -r --arg lang "$lang_key" '.skills.languages[$lang].weight // 0.3' "$K_PROFILE" 2>/dev/null)
  lang_pts=$(echo "$lang_weight" | awk '{printf "%d", $1 * 10}')
  fit_score=$((fit_score + lang_pts + 8))
  [ "$assets_count" -gt 20 ] && fit_score=$((fit_score + 5))
  [ "$assets_count" -gt 5 ] && [ "$assets_count" -le 20 ] && fit_score=$((fit_score + 3))
  [ "$assets_count" -le 5 ] && fit_score=$((fit_score + 1))
  [ "$fit_score" -gt 30 ] && fit_score=30

  # TRACK (0-25) - HackerOne gets highest priority
  track_score=0
  case "$platform" in
    hackerone) track_score=10 ;;
    yeswehack) track_score=7 ;;
    intigriti) track_score=2 ;;
    *) track_score=0 ;;
  esac
  managed=$(echo "$prog" | jq -r '.managed // false')
  [ "$managed" = "true" ] && track_score=$((track_score + 3))
  track_score=$((track_score + 4))
  [ "$track_score" -gt 25 ] && track_score=25

  # ROI (0-25)
  roi_score=0
  if [ "$max_bounty" != "null" ] && [ "$max_bounty" != "0" ] && echo "$max_bounty" | grep -qP '^\d+$'; then
    if [ "$max_bounty" -ge 10000 ]; then roi_score=10
    elif [ "$max_bounty" -ge 5000 ]; then roi_score=8
    elif [ "$max_bounty" -ge 1000 ]; then roi_score=6
    elif [ "$max_bounty" -ge 500 ]; then roi_score=4
    else roi_score=2; fi
  else
    roi_score=5
  fi
  [ "$assets_count" -lt 10 ] && roi_score=$((roi_score + 8))
  [ "$assets_count" -ge 10 ] && [ "$assets_count" -lt 30 ] && roi_score=$((roi_score + 6))
  [ "$assets_count" -ge 30 ] && roi_score=$((roi_score + 3))
  [ "$assets_count" -lt 10 ] && roi_score=$((roi_score + 4))
  [ "$assets_count" -ge 10 ] && [ "$assets_count" -lt 30 ] && roi_score=$((roi_score + 2))
  [ "$roi_score" -gt 25 ] && roi_score=25

  # ACCESS (0-20)
  access_score=0
  [ "$has_github" = "true" ] && access_score=8 || [ "$assets_count" -gt 0 ] && access_score=4
  case "$language" in
    Python|Go|JavaScript|TypeScript) access_score=$((access_score + 5)) ;;
    Rust|Java) access_score=$((access_score + 3)) ;;
    C|C++) access_score=$((access_score + 2)) ;;
    *) access_score=$((access_score + 1)) ;;
  esac
  case "$language" in
    Python|Go|JavaScript|TypeScript) access_score=$((access_score + 4)) ;;
    *) access_score=$((access_score + 1)) ;;
  esac
  [ "$access_score" -gt 20 ] && access_score=20

  total_score=$((fit_score + track_score + roi_score + access_score))

  # Penalty for failures in last 7 days + circuit breaker
  fail_count=0
  if [ -n "$FAILURE_ISSUES" ]; then
    fail_count=$(echo "$FAILURE_ISSUES" | grep -c "$name" 2>/dev/null || echo 0)
  fi
  if [ "$fail_count" -ge 3 ]; then
    # Circuit breaker: 3+ failures this week → skip entirely
    total_score=0
  elif [ "$fail_count" -gt 0 ]; then
    penalty=$((fail_count * 8))
    [ "$penalty" -gt 24 ] && penalty=24
    total_score=$((total_score - penalty))
  fi

  jq -nc \
    --arg name "$name" --arg platform "$platform" --arg language "$language" \
    --argjson total "$total_score" --argjson fit "$fit_score" \
    --argjson track "$track_score" --argjson roi "$roi_score" --argjson access "$access_score" \
    --argjson max_bounty "$max_bounty" --argjson assets_count "$assets_count" \
    --argjson has_github "$has_github" \
    '{name:$name, platform:$platform, score_total:$total,
      score_breakdown:{fit:$fit, track_record:$track, roi:$roi, accessibility:$access},
      metadata:{language:$language, max_bounty:$max_bounty, assets_count:$assets_count, has_github:$has_github}}' \
    >> "$SCORED_FILE"
done < "$FILTERED_FILE"

SCORED_COUNT=$(wc -l < "$SCORED_FILE" 2>/dev/null || echo 0)
echo "[enrich] Scored: $SCORED_COUNT"

echo "[enrich] Step 4: Ranking + Selection..."
RANKED_FILE="memoria/targets-ranked.json"
jq -s 'sort_by(-.score_total) | .[:10]' "$SCORED_FILE" 2>/dev/null > "$RANKED_FILE" || echo '[]' > "$RANKED_FILE"

SCORED_ARRAY="/tmp/scored-array.json"
jq -s '.' "$SCORED_FILE" 2>/dev/null > "$SCORED_ARRAY"
SELECTOR_OUTPUT="/tmp/selector-output.json"
if [ -f "setup/selector.sh" ]; then
  bash setup/selector.sh "$SCORED_ARRAY" 2>/dev/null > "$SELECTOR_OUTPUT"
fi
SELECTED_JSON=$(jq '.selected_targets // []' "$SELECTOR_OUTPUT" 2>/dev/null || echo '[]')
SELECTED_COUNT=$(echo "$SELECTED_JSON" | jq 'length' 2>/dev/null || echo 0)
if [ "$SELECTED_COUNT" -eq 0 ]; then
  SELECTED_JSON=$(jq '.[:5]' "$RANKED_FILE" 2>/dev/null || echo '[]')
fi

TOP_CANDIDATE=$(jq -r '.[0] // empty' "$RANKED_FILE" 2>/dev/null)
TOP_SCORE=$(echo "$TOP_CANDIDATE" | jq -r '.score_total // 0' 2>/dev/null)
TOP_NAME=$(echo "$TOP_CANDIDATE" | jq -r '.name // ""' 2>/dev/null)
echo "[enrich] Top: $TOP_NAME ($TOP_SCORE)"
echo "[enrich] Selected: $(echo "$SELECTED_JSON" | jq 'length' 2>/dev/null || echo 0) targets with justification"

echo "[enrich] Step 5: Writing output..."
RANKED_JSON=$(jq '.[:5] | map({name, platform, score_total, score_breakdown, metadata})' "$RANKED_FILE" 2>/dev/null || echo '[]')

jq -n \
  --arg ts "$TS" --arg date "$DATE" \
  --argjson h1 "${H1_COUNT:-0}" --argjson bc "${BC_COUNT:-0}" --argjson it "${IT_COUNT:-0}" --argjson yw "${YWH_COUNT:-0}" \
  --arg top_name "$TOP_NAME" --argjson top_score "${TOP_SCORE:-0}" \
  --argjson candidates "$RANKED_JSON" --argjson selected "$SELECTED_JSON" \
  --argjson filtered "$FILTERED_COUNT" --argjson scored "$SCORED_COUNT" \
  '{scan_date:$ts, date:$date,
    platforms:{hackerone:$h1, bugcrowd:$bc, intigriti:$it, yeswehack:$yw},
    stats:{filtered:$filtered, scored:$scored, selected:($selected|length)},
    top_candidate:{name:$top_name, score:$top_score},
    ranked_targets:$candidates, selected_targets:$selected}' \
  > "memoria/agent3-latest.json" 2>/dev/null || echo '{"error":"output_failed"}' > "memoria/agent3-latest.json"

REPORT="reports/scanner-${DATE}.md"
cat > "$REPORT" << REPORTEOF
# Scanner Report - ${DATE}
Generated: $TS

## Platforms
| Platform | Targets |
|----------|---------|
| HackerOne | $H1_COUNT |
| Bugcrowd | $BC_COUNT |
| Intigriti | $IT_COUNT |
| YesWeHack | $YWH_COUNT |

## Results
- Extracted: $TOTAL_PROGRAMS
- Filtered: $FILTERED_COUNT
- Scored: $SCORED_COUNT

## Top Candidates
| Score | Fit | Track | ROI | Access | Platform | Target | Language | Bounty |
|-------|-----|-------|-----|--------|----------|--------|----------|--------|
$(jq -r '.[] | "\(.score_total) | \(.score_breakdown.fit) | \(.score_breakdown.track_record) | \(.score_breakdown.roi) | \(.score_breakdown.accessibility) | \(.platform) | \(.name) | \(.metadata.language) | \(.metadata.max_bounty // "-")"' "$RANKED_FILE" 2>/dev/null | head -10 | while IFS='|' read -r s f t r a p n l b; do printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" "$s" "$f" "$t" "$r" "$a" "$p" "$n" "$l" "$b"; done || echo "*None*")
REPORTEOF

git add memoria/k-profile.json tasks/ 2>/dev/null || true
git add -f "reports/scanner-${DATE}.md" "memoria/agent3-latest.json" "memoria/targets-ranked.json" 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.name="enrich-bot" -c user.email="enrich@nex.local" commit -m "enrich: scan ${DATE}" 2>/dev/null || true
  git push origin main 2>/dev/null && echo "[enrich] Pushed" || echo "[enrich] Push failed"
fi

echo "[enrich] Done - Top: $TOP_NAME ($TOP_SCORE)"
exit 0
