#!/usr/bin/env bash
set -uo pipefail

# enrich.sh - Run on ubuntu-latest (FREE)
# Fetches bounty data, does GitHub API enrichment, produces ranked targets
# Output: memoria/targets-ranked.json, memoria/agent3-latest.json

# Ensure /tmp is in PATH (for custom jq binary if needed)
export PATH="/tmp:$PATH"

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

# === Validate token ===
echo "[enrich] Validating GitHub token..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $GH_PAT" "https://api.github.com/user" 2>/dev/null)
if [ "$HTTP_CODE" != "200" ]; then
  echo "[enrich] ERROR: Invalid token (HTTP $HTTP_CODE)"
  echo "[enrich] Token length: ${#GH_PAT}"
  exit 1
fi
echo "[enrich] Token valid (HTTP $HTTP_CODE)"

# Check rate limit
RATE_RESP=$(curl -s -H "Authorization: token $GH_PAT" "https://api.github.com/rate_limit" 2>/dev/null)
RATE_REMAINING=$(echo "$RATE_RESP" | jq -r '.rate.remaining // 0' 2>/dev/null)
RATE_LIMIT=$(echo "$RATE_RESP" | jq -r '.rate.limit // 0' 2>/dev/null)
echo "[enrich] GitHub API rate limit: $RATE_REMAINING / $RATE_LIMIT remaining"

if [ "$RATE_REMAINING" -lt 100 ]; then
  echo "[enrich] WARNING: Low rate limit ($RATE_REMAINING remaining). Enrichment may be limited."
fi

# === Clone repo ===
REPO_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
cd "$REPO_DIR" || exit 1
gh auth setup-git 2>/dev/null || true
git pull origin main 2>/dev/null || true

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
    DIFF_SECTION="${DIFF_SECTION}### ${label}\\n"
    [ -n "$new_str" ] && DIFF_SECTION="${DIFF_SECTION}**New ($(echo "$new_str" | wc -l):**\\n\`\\`\\`\n$new_str\n\`\\`\\`\n"
    [ -n "$rem_str" ] && DIFF_SECTION="${DIFF_SECTION}**Removed ($(echo "$rem_str" | wc -l):**\\n\`\\`\\`\n$rem_str\n\`\\`\\`\n"
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
# Scoring Pipeline (Base + GitHub Bonus)
# =====================================================================
echo "[enrich] Scoring all targets..."

RANKED_FILE="memoria/targets-ranked.json"
ENRICH_LOG="memoria/enrich-log-${DATE}.txt"
echo "[enrich] Enrichment log: $ENRICH_LOG" > "$ENRICH_LOG"
echo "[enrich] Rate limit at start: $RATE_REMAINING" >> "$ENRICH_LOG"

# Extract ALL programs with full data for base scoring
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

# Extract github.com URLs from in_scope targets (for GitHub bonus)
extract_gh_urls() {
  local json="$1" platform="$2"
  jq -rc '
    [.[] | select(.targets.in_scope != null) |
     {name: .name, url: .url,
      assets: [(.targets.in_scope[] |
        (.asset_identifier // .target // .uri // .endpoint // "") | select(length > 0)),
       (.targets.in_scope[] | .instruction // "" | select(length > 0)),
       (.targets.in_scope[] | .description // "" | select(length > 0))]}]
    | .[] | select(.assets | length > 0) |
    {name, purl: .url, assets}
  ' "$json" 2>> "$ENRICH_LOG"
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

# Base scoring WITHOUT GitHub dependency (for ALL programs)
# Uses: bounty amount, wildcard, managed, response efficiency, platform, assets
score_target_base() {
  local name="$1" platform="$2" max_bounty="$3" has_wildcard="$4" managed="$5" response_eff="$6" assets_count="$7"
  
  local score=0
  
  # Bounty amount (0-35 pts)
  if [ -n "$max_bounty" ] && [ "$max_bounty" != "null" ] && [ "$max_bounty" != "0" ]; then
    if [ "$max_bounty" -ge 10000 ]; then
      score=$((score + 35))
    elif [ "$max_bounty" -ge 5000 ]; then
      score=$((score + 30))
    elif [ "$max_bounty" -ge 2000 ]; then
      score=$((score + 25))
    elif [ "$max_bounty" -ge 1000 ]; then
      score=$((score + 20))
    elif [ "$max_bounty" -ge 500 ]; then
      score=$((score + 15))
    elif [ "$max_bounty" -ge 100 ]; then
      score=$((score + 10))
    else
      score=$((score + 5))
    fi
  else
    score=$((score + 8))  # Neutral for unknown bounty
  fi
  
  # Wildcard scope bonus (0-20 pts) - more surface area
  [ "$has_wildcard" = "true" ] && score=$((score + 20))
  
  # Managed program bonus (0-15 pts) - better triage
  [ "$managed" = "true" ] && score=$((score + 15))
  
  # Response efficiency bonus (0-10 pts) - H1 specific
  if [ -n "$response_eff" ] && [ "$response_eff" != "null" ]; then
    if [ "$response_eff" -ge 90 ]; then
      score=$((score + 10))
    elif [ "$response_eff" -ge 80 ]; then
      score=$((score + 7))
    elif [ "$response_eff" -ge 70 ]; then
      score=$((score + 4))
    fi
  fi
  
  # Assets in scope (0-15 pts)
  local assets_score=$((assets_count * 2))
  [ "$assets_score" -gt 15 ] && assets_score=15
  score=$((score + assets_score))
  
  # Platform bonus (0-5 pts) - prioritize proven platform
  case "$platform" in
    hackerone) score=$((score + 5)) ;;
    *)         ;;  # Other platforms = no bonus
  esac
  
  echo "$score"
}

# GitHub enrichment bonus (adds to base score)
# Uses: language, size, stars, pushed_at
score_github_bonus() {
  local lang="$1" size="$2" stars="$3" pushed="$4" surface_type="$5"
  
  local bonus=0
  
  # Language fit (0-15 pts)
  case "$lang" in
    "Python") bonus=$((bonus + 15)) ;;
    "Go")     bonus=$((bonus + 13)) ;;
    "C"|"C++"|"Rust") bonus=$((bonus + 12)) ;;
    "TypeScript"|"JavaScript") bonus=$((bonus + 8)) ;;
    "Java")   bonus=$((bonus + 6)) ;;
    *)        bonus=$((bonus + 3)) ;;
  esac
  
  # Size sweet spot (0-5 pts)
  [ "$size" -lt 30000 ] && bonus=$((bonus + 5))
  [ "$size" -gt 100000 ] && bonus=$((bonus - 2))
  
  # Staleness penalty
  local stale=$(date -d "$pushed" +%s 2>/dev/null || echo 0)
  local now=$(date +%s)
  [ $(( (now - stale) / 86400 )) -gt 365 ] && bonus=$((bonus - 3))
  [ "$bonus" -lt 0 ] && bonus=0
  
  echo "$bonus"
}

# =====================================================================
# BASE SCORING (works without GitHub)
# =====================================================================
echo "[enrich] Scoring ALL programs (base scoring)..."

RANKED_FILE="memoria/targets-ranked.json"
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
  PROG_COUNT=$(grep -c "\"name\"" "$ALL_PROGRAMS_FILE" 2>/dev/null || echo 0)
  echo "[enrich] $BPLABEL: $PROG_COUNT programs total"
done

TOTAL_PROGRAMS=$(wc -l < "$ALL_PROGRAMS_FILE")
echo "[enrich] Total programs to score: $TOTAL_PROGRAMS"

# Score each program with base scoring
echo "[" > "$RANKED_FILE.tmp"
first=true
SCORED=0

while IFS= read -r prog; do
  [ -z "$prog" ] && continue
  
  name=$(echo "$prog" | jq -r '.name // ""')
  platform=$(echo "$prog" | jq -r '.platform // ""')
  url=$(echo "$prog" | jq -r '.url // ""')
  max_bounty=$(echo "$prog" | jq -r '.max_bounty // "null"')
  has_wildcard=$(echo "$prog" | jq -r '.has_wildcard')
  managed=$(echo "$prog" | jq -r '.managed')
  response_eff=$(echo "$prog" | jq -r '.response_efficiency // "null"')
  assets_count=$(echo "$prog" | jq -r '.assets_count')
  
  [ -z "$name" ] || [ "$name" = "null" ] && continue
  
  # Base score (without GitHub)
  base_score=$(score_target_base "$name" "$platform" "$max_bounty" "$has_wildcard" "$managed" "$response_eff" "$assets_count")
  
  [ "$base_score" -eq 0 ] && continue
  
  echo "[enrich] BASE_SCORE: $name ($platform) -> $base_score (bounty=$max_bounty wc=$has_wildcard mg=$managed)" >> "$ENRICH_LOG"
  
  entry=$(jq -nc --arg name "$name" --arg platform "$platform" --arg url "$url" --argjson base_score "$base_score" --argjson max_bounty "$max_bounty" --argjson has_wildcard "$has_wildcard" --argjson managed "$managed" --argjson assets_count "$assets_count" --arg ts "$TS" '{name:$name,platform:$platform,url:$url,repo:null,language:null,stars:0,score:$base_score,base_score:$base_score,github_bonus:0,max_bounty:$max_bounty,has_wildcard:$has_wildcard,managed:$managed,assets_count:$assets_count,scored_at:$ts}')
  if [ "$first" = true ]; then echo "$entry" >> "$RANKED_FILE.tmp"; first=false; else echo ",$entry" >> "$RANKED_FILE.tmp"; fi
  SCORED=$((SCORED + 1))
done < "$ALL_PROGRAMS_FILE"

echo "]" >> "$RANKED_FILE.tmp"
echo "[enrich] Base scoring done: $SCORED programs scored"
echo "[enrich] Base scoring done: $SCORED programs scored" >> "$ENRICH_LOG"

jq 'sort_by(-.score) | .[:10]' "$RANKED_FILE.tmp" 2>/dev/null > "$RANKED_FILE" || echo '[]' > "$RANKED_FILE"

# =====================================================================
# GITHUB ENRICHMENT (optional bonus for top candidates)
# =====================================================================
echo "[enrich] Adding GitHub bonus for top candidates..."

# Get top 20 candidates for GitHub enrichment (save API calls)
TOP20_FILE="/tmp/top20-candidates.json"
jq -r '.[:20] | .[] | .name' "$RANKED_FILE" 2>/dev/null > /tmp/top20-names.txt

# Extract GitHub URLs for these candidates
ALL_REPOS_FILE="/tmp/all-repos-github.txt"
> "$ALL_REPOS_FILE"

for platform in hackerone bugcrowd intigriti yeswehack; do
  case "$platform" in
    hackerone) JSON="$H1_JSON"; BPLABEL="H1" ;;
    bugcrowd)  JSON="$BC_JSON"; BPLABEL="BC" ;;
    intigriti) JSON="$IT_JSON"; BPLABEL="IT" ;;
    yeswehack) JSON="$YWH_JSON"; BPLABEL="YWH" ;;
  esac
  [ ! -f "$JSON" ] && continue
  
  # Only extract for top candidates
  while IFS= read -r target_name; do
    [ -z "$target_name" ] && continue
    # Find this program in JSON and extract GitHub URLs
    jq -rc --arg name "$target_name" '
      .[] | select(.name == $name and .targets.in_scope != null) |
      {name: .name, url: .url,
       assets: [.targets.in_scope[] |
         (.asset_identifier // .target // .uri // .endpoint // "") |
         select(test("github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_*.+-]+"))]}
      | select(.assets | length > 0) |
      {name, purl: .url, assets}
    ' "$JSON" 2>/dev/null | while read -r prog; do
      pname=$(echo "$prog" | jq -r '.name')
      purl=$(echo "$prog" | jq -r '.purl')
      echo "$prog" | jq -r '.assets[]' 2>/dev/null | while read -r asset; do
        ghurl=$(echo "$asset" | grep -ioE '(https?://)?github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_*.+-]+' 2>/dev/null || true)
        [ -z "$ghurl" ] && continue
        ghurl=$(echo "$ghurl" | sed 's|^https\?://||; s|^|https://|; s|\.git$||; s|/$||')
        owner_repo=$(echo "$ghurl" | sed 's|https://github\.com/||')
        echo "$owner_repo" | grep -q '\*' && continue
        echo "$BPLABEL|$pname|$purl|$owner_repo" >> "$ALL_REPOS_FILE"
      done
    done
  done < /tmp/top20-names.txt
done

# Deduplicate and fetch
UNIQUE_REPOS_FILE="/tmp/unique-repos-github.txt"
awk -F'|' '{print $4}' "$ALL_REPOS_FILE" | sort -u > "$UNIQUE_REPOS_FILE"
TOTAL_REPOS_GH=$(wc -l < "$UNIQUE_REPOS_FILE")
echo "[enrich] GitHub enrichment: $TOTAL_REPOS_GH repos to fetch"

# Repo cache
REPO_CACHE="memoria/repo-cache.json"
[ -f "$REPO_CACHE" ] || echo '{}' > "$REPO_CACHE"

# Batch fetch function
fetch_repo_batch() {
  local batch_file="$1"
  local batch_num="$2"
  local batch_ok=0
  local batch_404=0
  local batch_err=0
  
  while read -r owner_repo; do
    # Check cache first
    cached=$(jq -r --arg r "$owner_repo" '.[$r] // empty' "$REPO_CACHE" 2>/dev/null)
    if [ -n "$cached" ]; then
      echo "CACHED|$owner_repo|$cached"
      batch_ok=$((batch_ok + 1))
      continue
    fi
    
    # API call
    api_resp=$(curl -s -w "\n%{http_code}" -H "Authorization: token $GH_PAT" "https://api.github.com/repos/$owner_repo" 2>&1)
    http_code=$(echo "$api_resp" | tail -1)
    api_resp=$(echo "$api_resp" | sed '$d')
    message=$(echo "$api_resp" | jq -r '.message // ""' 2>/dev/null)
    
    if [ "$http_code" = "403" ] && echo "$message" | grep -qi "rate limit"; then
      echo "RATE_LIMIT|$owner_repo"
      echo "[enrich] RATE LIMIT HIT at batch $batch_num after $batch_ok OK repos" >> "$ENRICH_LOG"
      break
    fi
    
    if [ "$message" = "Not Found" ] || [ -z "$api_resp" ]; then
      echo "404|$owner_repo"
      batch_404=$((batch_404 + 1))
      continue
    fi
    
    if [ "$http_code" != "200" ]; then
      echo "ERR|$owner_repo|HTTP$http_code"
      echo "[enrich] API ERROR: $owner_repo -> HTTP $http_code ($message)" >> "$ENRICH_LOG"
      batch_err=$((batch_err + 1))
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
    batch_ok=$((batch_ok + 1))
  done < "$batch_file"
  
  echo "[enrich] Batch $batch_num: $batch_ok OK, $batch_404 not found, $batch_err errors" >> "$ENRICH_LOG"
}

# Fetch in batches
RESULTS_FILE_GH="/tmp/enrich-results-github.txt"
> "$RESULTS_FILE_GH"
BATCH_NUM_GH=0

if [ "$TOTAL_REPOS_GH" -gt 0 ]; then
  split -l 50 "$UNIQUE_REPOS_FILE" /tmp/batch-gh-
  for batch_file in /tmp/batch-gh-*; do
    [ ! -f "$batch_file" ] && continue
    BATCH_NUM_GH=$((BATCH_NUM_GH + 1))
    fetch_repo_batch "$batch_file" "$BATCH_NUM_GH" >> "$RESULTS_FILE_GH"
  done
  rm -f /tmp/batch-gh-*
fi

# Merge GitHub bonus into ranked results
echo "[enrich] Merging GitHub bonus into final scores..."

# Create temp file with updated scores
jq '.' "$RANKED_FILE.tmp" > /tmp/ranked-base.json

# For each program with GitHub data, add bonus
while IFS='|' read -r owner_repo; do
  result=$(grep "^OK|$owner_repo\|^CACHED|$owner_repo" "$RESULTS_FILE_GH" | head -1)
  [ -z "$result" ] && continue
  
  IFS='|' read -r status repo lang size stars pushed desc topics <<< "$result"
  
  # Find programs that reference this repo
  grep "|$owner_repo$" "$ALL_REPOS_FILE" | awk -F'|' '{print $2}' | sort -u | while read -r pname; do
    [ -z "$pname" ] && continue
    
    # Calculate GitHub bonus
    surface_type=15  # default
    gh_bonus=$(score_github_bonus "$lang" "$size" "$stars" "$pushed" "$surface_type")
    
    echo "[enrich] GITHUB_BONUS: $pname (+$gh_bonus) lang=$lang stars=$stars" >> "$ENRICH_LOG"
    
    # Update score in ranked file
    jq --arg name "$pname" --argjson bonus "$gh_bonus" --arg repo "https://github.com/$owner_repo" --arg lang "$lang" --argjson stars "$stars" \
      'map(if .name == $name then .github_bonus = $bonus | .score = (.base_score + $bonus) | .repo = $repo | .language = $lang | .stars = $stars else . end)' \
      /tmp/ranked-base.json > /tmp/ranked-updated.json 2>/dev/null && \
      mv /tmp/ranked-updated.json /tmp/ranked-base.json
  done
done < "$UNIQUE_REPOS_FILE"

# Sort by final score and take top 10
jq 'sort_by(-.score) | .[:10]' /tmp/ranked-base.json > "$RANKED_FILE" 2>/dev/null || echo '[]' > "$RANKED_FILE"
rm -f "$RANKED_FILE.tmp" /tmp/ranked-base.json

echo "[enrich] GitHub enrichment done"

# Compute stats from results
OK_COUNT=$(grep -c '^OK|' "$RESULTS_FILE_GH" 2>/dev/null || echo 0)
CACHED_COUNT=$(grep -c '^CACHED|' "$RESULTS_FILE_GH" 2>/dev/null || echo 0)
RATE_COUNT=$(grep -c '^RATE_LIMIT|' "$RESULTS_FILE_GH" 2>/dev/null || echo 0)
ERR_COUNT=$(grep -cE '^404\||^ERR\|' "$RESULTS_FILE_GH" 2>/dev/null || echo 0)
TOTAL_REPOS=$TOTAL_REPOS_GH

TOP_CANDIDATES=$(jq -r '.[0] // empty' "$RANKED_FILE" 2>/dev/null)
TOP_SCORE=$(echo "$TOP_CANDIDATES" | jq -r '.score // 0' 2>/dev/null)
RANKED_COUNT=$(jq 'length' "$RANKED_FILE" 2>/dev/null || echo 0)

echo "[enrich] Ranked targets: $RANKED_COUNT"
echo "[enrich] Top candidate: $(echo "$TOP_CANDIDATES" | jq -r '.name // "none"') (score: $TOP_SCORE)"

# === Save agent3-latest.json ===
TOP_NAME=$(echo "${TOP_CANDIDATES:-}" | jq -r '.name // ""' 2>/dev/null || echo "")
RANKED_JSON=$(jq '.[:5] | map({name, platform, repo, language, score, base_score, github_bonus, max_bounty, has_wildcard, managed})' "${RANKED_FILE}" 2>/dev/null || echo '[]')
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
  QUICK_SCAN="## Quick Scan (new targets)\\n| Target | URL | HTTP |\\n|--------|-----|------|\\n"
  while IFS='|' read -r name url; do
    [ -z "$name" ] && continue
    http=$(curl -sI -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 5 "$url" 2>/dev/null || echo "ERR")
    QUICK_SCAN="${QUICK_SCAN}| $name | $url | $http |\\n"
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

## API Enrichment Results
- Unique repos found: $TOTAL_REPOS
- Repos fetched (fresh): $OK_COUNT
- Repos cached: $CACHED_COUNT
- Rate limited: $RATE_COUNT
- Errors/404: $ERR_COUNT
- Targets scored: $SCORED

## Top Candidates (scored)
| Score | Base | GH+ | Platform | Target | Lang | Stars | Bounty | Wild | Managed | Repo |
|-------|------|-----|----------|--------|------|-------|--------|------|---------|------|
$(jq -r '.[] | "\(.score) | \(.base_score) | \(.github_bonus) | \(.platform) | \(.name) | \(.language // "-") | \(.stars // 0) | \(.max_bounty // "-") | \(.has_wildcard) | \(.managed) | \(.repo // "-")"' "$RANKED_FILE" 2>/dev/null | head -10 | while IFS='|' read -r score base gh plat name lang stars bounty wild managed repo; do printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" "$score" "$base" "$gh" "$plat" "$name" "$lang" "$stars" "$bounty" "$wild" "$managed" "$repo"; done || echo "*No programs scored*")

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
