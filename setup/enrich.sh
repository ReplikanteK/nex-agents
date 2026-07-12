#!/usr/bin/env bash
set -uo pipefail

# enrich.sh - Personalized enrichment pipeline
# Runs on ubuntu-latest (FREE)
# Output: memoria/targets-ranked.json, memoria/agent3-latest.json

export PATH="/tmp:$PATH"

GH_PAT="${1:-${GITHUB_TOKEN:-}}"
[ -z "$GH_PAT" ] && echo "[enrich] No token" && exit 1
export GH_TOKEN="$GH_PAT"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DATE=$(date +%Y-%m-%d)
DOW=$(date +%u)
echo "[enrich] $TS - Personalized enrichment starting... (day $DOW)"

# === Health check ===
for cmd in gh git curl jq bc; do
  command -v "$cmd" &>/dev/null || { echo "[enrich] Missing: $cmd"; exit 1; }
done

# === Validate token ===
echo "[enrich] Validating GitHub token..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $GH_PAT" "https://api.github.com/user" 2>/dev/null)
if [ "$HTTP_CODE" != "200" ]; then
  echo "[enrich] ERROR: Invalid token (HTTP $HTTP_CODE)"
  exit 1
fi
echo "[enrich] Token valid (HTTP $HTTP_CODE)"

# Check rate limit
RATE_RESP=$(curl -s -H "Authorization: token $GH_PAT" "https://api.github.com/rate_limit" 2>/dev/null)
RATE_REMAINING=$(echo "$RATE_RESP" | jq -r '.rate.remaining // 0' 2>/dev/null)
echo "[enrich] GitHub API rate limit: $RATE_REMAINING remaining"

if [ "$RATE_REMAINING" -lt 100 ]; then
  echo "[enrich] WARNING: Low rate limit. Enrichment may be limited."
fi

# === Clone repo ===
REPO_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$REPO_DIR" || exit 1
gh auth setup-git 2>/dev/null || true
git pull origin main 2>/dev/null || true

# === Load K Profile ===
K_PROFILE="memoria/k-profile.json"
if [ ! -f "$K_PROFILE" ]; then
  echo "[enrich] ERROR: K-profile not found"
  exit 1
fi
echo "[enrich] K-profile loaded"

# === Fetch bounty data ===
BOUNTY_DIR="/tmp/bounty-targets-data"
if [ ! -d "$BOUNTY_DIR/.git" ]; then
  git clone --depth 1 https://github.com/arkadiyt/bounty-targets-data.git "$BOUNTY_DIR" 2>&1 | tail -3
else
  git -C "$BOUNTY_DIR" pull origin master 2>&1 | tail -3
fi

if [ ! -f "$BOUNTY_DIR/data/hackerone_data.json" ]; then
  echo "[enrich] ERROR: bounty-targets-data not found"
  exit 1
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

H1_COUNT=$(echo "$H1_NOW" | grep -c . 2>/dev/null || echo 0)
BC_COUNT=$(echo "$BC_NOW" | grep -c . 2>/dev/null || echo 0)
IT_COUNT=$(echo "$IT_NOW" | grep -c . 2>/dev/null || echo 0)
YWH_COUNT=$(echo "$YWH_NOW" | grep -c . 2>/dev/null || echo 0)

echo "[enrich] Targets: H1=$H1_COUNT BC=$BC_COUNT IT=$IT_COUNT YWH=$YWH_COUNT"

# Diff logic
if [ -f "$STATE_FILE" ]; then
  H1_PREV=$(jq -r '.targets.hackerone[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
  BC_PREV=$(jq -r '.targets.bugcrowd[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
  IT_PREV=$(jq -r '.targets.intigriti[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
  YWH_PREV=$(jq -r '.targets.yeswehack[]? | "\(.name)|\(.url // "?")"' "$STATE_FILE" 2>/dev/null | sort -u)
else
  H1_PREV=""; BC_PREV=""; IT_PREV=""; YWH_PREV=""
fi

# Save full state
write_platform() { jq '[.[] | {name, url}]' "$1" 2>/dev/null || echo '[]'; }
jq -n --arg ts "$TS" --argjson h1 "$(write_platform "$H1_JSON")" --argjson bc "$(write_platform "$BC_JSON")" --argjson it "$(write_platform "$IT_JSON")" --argjson yw "$(write_platform "$YWH_JSON")" '{last_scan: $ts, targets: {hackerone: $h1, bugcrowd: $bc, intigriti: $it, yeswehack: $yw}}' > "$STATE_FILE"

# =====================================================================
# PERSONALIZED SCORING PIPELINE
# =====================================================================
echo "[enrich] Starting personalized scoring pipeline..."

RANKED_FILE="memoria/targets-ranked.json"
ENRICH_LOG="memoria/enrich-log-${DATE}.txt"
echo "[enrich] Enrichment log: $ENRICH_LOG" > "$ENRICH_LOG"

# Extract ALL programs with full data
extract_programs_full() {
  local json="$1" platform="$2"
  jq -rc --arg platform "$platform" '
    [.[] | select(.targets.in_scope != null) |
     {name: .name, url: .url,
      platform: $platform,
      offers_bounties: (.offers_bounties // false),
      managed: (.managed_program // .managed_by_bugcrowd // false),
      response_efficiency: (.response_efficiency_percentage // null),
      max_bounty: (.max_bounty.value // .max_payout // null),
      min_bounty: (.min_bounty.value // null),
      assets_count: ([.targets.in_scope[] | select(.eligible_for_bounty == true)] | length),
      has_wildcard: ([.targets.in_scope[] | select(.asset_identifier // .target // .uri // .endpoint // "" | test("\\*"))] | length > 0),
      github_urls: [.targets.in_scope[] |
        (.asset_identifier // .target // .uri // .endpoint // "") |
        select(test("github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_*.+-]+"))]}]
    | .[] |
    {name, url, platform, offers_bounties, managed, response_efficiency, max_bounty, min_bounty, assets_count, has_wildcard, github_urls}
  ' "$json" 2>> "$ENRICH_LOG"
}

# =====================================================================
# STEP 1: Extract all programs
# =====================================================================
echo "[enrich] Step 1: Extracting all programs..."

ALL_PROGRAMS_FILE="/tmp/all-programs.json"
> "$ALL_PROGRAMS_FILE"

for platform in hackerone bugcrowd intigriti yeswehack; do
  case "$platform" in
    hackerone) JSON="$H1_JSON"; BPLABEL="H1" ;;
    bugcrowd)  JSON="$BC_JSON"; BPLABEL="BC" ;;
    intigriti) JSON="$IT_JSON"; BPLABEL="IT" ;;
    yeswehack) JSON="$YWH_JSON"; BPLABEL="YWH" ;;
  esac
  [ ! -f "$JSON" ] && { echo "[enrich] SKIP: $JSON not found"; continue; }

  echo "[enrich] Extracting programs from $BPLABEL..."
  extract_programs_full "$JSON" "$platform" | while read -r prog; do
    echo "$prog" >> "$ALL_PROGRAMS_FILE"
  done
done

TOTAL_PROGRAMS=$(wc -l < "$ALL_PROGRAMS_FILE")
echo "[enrich] Total programs to score: $TOTAL_PROGRAMS"

# =====================================================================
# STEP 2: Apply hard filters
# =====================================================================
echo "[enrich] Step 2: Applying hard filters..."

FILTERED_FILE="/tmp/filtered-programs.json"
> "$FILTERED_FILE"

while IFS= read -r prog; do
  [ -z "$prog" ] && continue
  
  name=$(echo "$prog" | jq -r '.name // ""')
  platform=$(echo "$prog" | jq -r '.platform // ""')
  offers_bounties=$(echo "$prog" | jq -r '.offers_bounties // false')
  assets_count=$(echo "$prog" | jq -r '.assets_count // 0')
  max_bounty=$(echo "$prog" | jq -r '.max_bounty // "null"')
  
  passed="true"
  reject_reason=""
  
  name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
  if echo "$name_lower" | grep -qiE '(government|military|gov\.|army|navy)'; then
    passed="false"
    reject_reason="government"
  fi
  
  if [ "$passed" = "true" ]; then
    can_submit=$(jq -r --arg p "$platform" '.track_record.platform_status[$p].can_submit // false' "$K_PROFILE" 2>/dev/null)
    if [ "$can_submit" != "true" ]; then
      passed="false"
      reject_reason="platform_cooldown"
    fi
  fi
  
  if [ "$passed" = "true" ]; then
    min_required=$(jq -r '.preferences.min_bounty_usd // 500' "$K_PROFILE" 2>/dev/null)
    if [ -n "$max_bounty" ] && [ "$max_bounty" != "null" ] && [ "$max_bounty" != "0" ]; then
      if [ "$max_bounty" -lt "$min_required" ]; then
        passed="false"
        reject_reason="bounty_too_low"
      fi
    fi
  fi
  
  if [ "$passed" = "true" ]; then
    if echo "$name_lower" | grep -qiE '(lightspark|uber|airbnb|shopify)'; then
      passed="false"
      reject_reason="saturated"
    fi
  fi
  
  if [ "$passed" = "true" ]; then
    echo "$prog" >> "$FILTERED_FILE"
  fi
done < "$ALL_PROGRAMS_FILE"

FILTERED_COUNT=$(wc -l < "$FILTERED_FILE")
echo "[enrich] Programs after filtering: $FILTERED_COUNT"

# =====================================================================
# STEP 3: Personalized scoring
# =====================================================================
echo "[enrich] Step 3: Applying personalized scoring..."

SCORED_FILE="/tmp/scored-programs.json"
> "$SCORED_FILE"

while IFS= read -r prog; do
  [ -z "$prog" ] && continue
  
  name=$(echo "$prog" | jq -r '.name // ""')
  platform=$(echo "$prog" | jq -r '.platform // ""')
  language=$(echo "$prog" | jq -r '.language // ""')
  repo_size=$(echo "$prog" | jq -r '.repo_size // 0')
  max_bounty=$(echo "$prog" | jq -r '.max_bounty // "null"')
  assets_count=$(echo "$prog" | jq -r '.assets_count // 0')
  has_github=$(echo "$prog" | jq -r '.github_urls | length > 0')
  
  [ -z "$language" ] || [ "$language" = "null" ] && language="unknown"
  [ -z "$repo_size" ] || [ "$repo_size" = "null" ] && repo_size=0
  
  estimated_hours=4
  [ "$repo_size" -gt 0 ] && [ "$repo_size" -lt 10000 ] && estimated_hours=2
  [ "$repo_size" -gt 50000 ] && estimated_hours=6
  
  fit_score=0
  lang_weight=$(jq -r --arg lang "$language" '.skills.languages[$lang].weight // 0.3' "$K_PROFILE" 2>/dev/null)
  lang_pts=$(echo "$lang_weight" | awk '{printf "%d", $1 * 10}')
  fit_score=$((fit_score + lang_pts + 5 + 8))
  [ "$fit_score" -gt 30 ] && fit_score=30
  
  track_score=0
  case "$platform" in
    yeswehack) track_score=$((track_score + 8)) ;;
    hackerone) track_score=$((track_score + 6)) ;;
    intigriti) track_score=$((track_score + 2)) ;;
  esac
  track_score=$((track_score + 4))
  [ "$track_score" -gt 25 ] && track_score=25
  
  roi_score=0
  if [ -n "$max_bounty" ] && [ "$max_bounty" != "null" ] && [ "$max_bounty" != "0" ]; then
    if [ "$max_bounty" -ge 10000 ]; then roi_score=$((roi_score + 10))
    elif [ "$max_bounty" -ge 5000 ]; then roi_score=$((roi_score + 8))
    elif [ "$max_bounty" -ge 1000 ]; then roi_score=$((roi_score + 6))
    elif [ "$max_bounty" -ge 500 ]; then roi_score=$((roi_score + 4))
    else roi_score=$((roi_score + 2))
    fi
  else
    roi_score=$((roi_score + 5))
  fi
  time_score=4
  [ "$estimated_hours" -le 2 ] && time_score=8
  [ "$estimated_hours" -le 4 ] && time_score=6
  roi_score=$((roi_score + time_score + 3))
  [ "$roi_score" -gt 25 ] && roi_score=25
  
  access_score=0
  [ "$has_github" = "true" ] && access_score=$((access_score + 8))
  [ "$assets_count" -gt 0 ] && [ "$has_github" != "true" ] && access_score=$((access_score + 4))
  [ "$repo_size" -gt 0 ] && [ "$repo_size" -lt 10000 ] && access_score=$((access_score + 5))
  [ "$repo_size" -gt 50000 ] && access_score=$((access_score + 2))
  [ "$repo_size" -eq 0 ] || [ "$repo_size" = "null" ] && access_score=$((access_score + 3))
  case "$language" in
    "Python"|"Go"|"JavaScript"|"TypeScript") access_score=$((access_score + 4)) ;;
    "Rust"|"Java") access_score=$((access_score + 3)) ;;
    "C"|"C++") access_score=$((access_score + 2)) ;;
    *) access_score=$((access_score + 1)) ;;
  esac
  access_score=$((access_score + 2))
  [ "$access_score" -gt 20 ] && access_score=20
  
  total_score=$((fit_score + track_score + roi_score + access_score))
  
  jq -n \
    --arg name "$name" \
    --arg platform "$platform" \
    --argjson total "$total_score" \
    --argjson fit "$fit_score" \
    --argjson track "$track_score" \
    --argjson roi "$roi_score" \
    --argjson access "$access_score" \
    --arg language "$language" \
    --argjson repo_size "$repo_size" \
    --argjson max_bounty "$max_bounty" \
    --argjson assets_count "$assets_count" \
    --argjson has_github "$has_github" \
    --argjson estimated_hours "$estimated_hours" \
    '{
      name: $name,
      platform: $platform,
      score_total: $total,
      score_breakdown: {fit: $fit, track_record: $track, roi: $roi, accessibility: $access},
      metadata: {language: $language, repo_size: $repo_size, max_bounty: $max_bounty, assets_count: $assets_count, has_github: $has_github, estimated_hours: $estimated_hours}
    }' >> "$SCORED_FILE"
done < "$FILTERED_FILE"

SCORED_COUNT=$(wc -l < "$SCORED_FILE")
echo "[enrich] Programs scored: $SCORED_COUNT"

# =====================================================================
# STEP 4: Select top targets
# =====================================================================
echo "[enrich] Step 4: Selecting top targets..."

jq -s 'sort_by(-.score_total) | .[:10]' "$SCORED_FILE" 2>/dev/null > "$RANKED_FILE" || echo '[]' > "$RANKED_FILE"

SELECTED_FILE="memoria/selected-targets.json"
jq -s 'sort_by(-.score_total) | .[:5]' "$SCORED_FILE" 2>/dev/null > "$SELECTED_FILE" || echo '[]' > "$SELECTED_FILE"

TOP_CANDIDATE=$(jq -r '.[0] // empty' "$RANKED_FILE" 2>/dev/null)
TOP_SCORE=$(echo "$TOP_CANDIDATE" | jq -r '.score_total // 0' 2>/dev/null)
TOP_NAME=$(echo "$TOP_CANDIDATE" | jq -r '.name // ""' 2>/dev/null)

echo "[enrich] Top candidate: $TOP_NAME (score: $TOP_SCORE)"

# =====================================================================
# STEP 5: Generate agent3-latest.json
# =====================================================================
echo "[enrich] Step 5: Generating output..."

RANKED_JSON=$(jq '.[:5] | map({name, platform, score_total, score_breakdown, metadata})' "$RANKED_FILE" 2>/dev/null || echo '[]')
SELECTED_JSON=$(jq '.' "$SELECTED_FILE" 2>/dev/null || echo '[]')

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
  --argjson selected "$SELECTED_JSON" \
  --argjson filtered "$FILTERED_COUNT" \
  --argjson scored "$SCORED_COUNT" \
  '{
    scan_date: $ts, date: $date, task: $task,
    platforms: {hackerone: ($h1|tonumber), bugcrowd: ($bc|tonumber), intigriti: ($it|tonumber), yeswehack: ($yw|tonumber)},
    stats: {filtered: $filtered, scored: $scored, selected: ($selected | length)},
    top_candidate: {name: $top_name, score: ($top_score|tonumber)},
    ranked_targets: $candidates,
    selected_targets: $selected
  }' > "memoria/agent3-latest.json" 2>/dev/null || echo '{"error":"generation_failed"}' > "memoria/agent3-latest.json"

# =====================================================================
# STEP 6: Generate scanner report
# =====================================================================
echo "[enrich] Step 6: Generating report..."

REPORT="reports/scanner-${DATE}.md"
cat > "$REPORT" << REPORTEOF
# Personalized Scanner Report - ${DATE}
- Generated: $TS
- Status: completed

## Bounty Targets Overview
| Platform | Targets |
|----------|---------|
| HackerOne | ${H1_COUNT} |
| Bugcrowd | ${BC_COUNT} |
| Intigriti | ${IT_COUNT} |
| YesWeHack | ${YWH_COUNT} |

## Personalized Scoring Results
- Programs evaluated: $TOTAL_PROGRAMS
- Programs filtered: $FILTERED_COUNT
- Programs scored: $SCORED_COUNT

## Top Candidates
| Score | Fit | Track | ROI | Access | Platform | Target | Language | Bounty |
|-------|-----|-------|-----|--------|----------|--------|----------|--------|
$(jq -r '.[] | "\(.score_total) | \(.score_breakdown.fit) | \(.score_breakdown.track_record) | \(.score_breakdown.roi) | \(.score_breakdown.accessibility) | \(.platform) | \(.name) | \(.metadata.language) | \(.metadata.max_bounty // "-")"' "$RANKED_FILE" 2>/dev/null | head -10 | while IFS='|' read -r score fit track roi access plat name lang bounty; do printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" "$score" "$fit" "$track" "$roi" "$access" "$plat" "$name" "$lang" "$bounty"; done || echo "*No programs scored*")
REPORTEOF

# === Commit and push ===
git add reports/ memoria/ tasks/ 2>/dev/null || true
if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.name="enrich-bot" -c user.email="enrich@nex.local" commit -m "enrich: personalized scan ${DATE}" 2>/dev/null || true
  git push origin main 2>/dev/null && echo "[enrich] Pushed" || echo "[enrich] Push failed"
fi

echo "[enrich] Done"
echo "[enrich] Top candidate: $TOP_NAME (score: $TOP_SCORE)"
exit 0
