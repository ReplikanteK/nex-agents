#!/usr/bin/env bash
set -uo pipefail

# score-personal.sh - Personalized scoring based on K's profile
PROFILE="${K_PROFILE:-memoria/k-profile.json}"

if [ ! -f "$PROFILE" ]; then
  echo "[score-personal] ERROR: K-profile not found at $PROFILE" >&2
  exit 1
fi

calculate_fit_score() {
  local language="$1"
  local vuln_types="$2"
  local surface_type="$3"
  
  local score=0
  
  local lang_weight=$(jq -r --arg lang "$language" '.skills.languages[$lang].weight // 0.3' "$PROFILE" 2>/dev/null)
  local lang_score=$(echo "$lang_weight" | awk '{printf "%d", $1 * 10}')
  score=$((score + lang_score))
  
  local vuln_score=5
  score=$((score + vuln_score))
  
  local surface_score=8
  score=$((score + surface_score))
  [ "$score" -gt 30 ] && score=30
  
  echo "$score"
}

calculate_track_record_score() {
  local target_name="$1"
  local platform="$2"
  local reports_total="$3"
  
  local score=0
  
  local platform_score=0
  case "$platform" in
    yeswehack)
      local can_submit=$(jq -r '.track_record.platform_status.yeswehack.can_submit // false' "$PROFILE" 2>/dev/null)
      [ "$can_submit" = "true" ] && platform_score=8
      ;;
    hackerone)
      local reports=$(jq -r '.track_record.platform_status.hackerone.reports_in_triage // 0' "$PROFILE" 2>/dev/null)
      [ "$reports" -gt 0 ] && platform_score=6
      ;;
    bugcrowd)
      platform_score=0
      ;;
    intigriti)
      platform_score=2
      ;;
  esac
  score=$((score + platform_score))
  
  local novelty_score=4
  score=$((score + novelty_score))
  [ "$score" -gt 25 ] && score=25
  
  echo "$score"
}

calculate_roi_score() {
  local max_bounty="$1"
  local estimated_hours="$2"
  local assets_count="$3"
  
  local score=0
  
  if [ -n "$max_bounty" ] && [ "$max_bounty" != "null" ] && [ "$max_bounty" != "0" ]; then
    if [ "$max_bounty" -ge 10000 ]; then score=$((score + 10))
    elif [ "$max_bounty" -ge 5000 ]; then score=$((score + 8))
    elif [ "$max_bounty" -ge 1000 ]; then score=$((score + 6))
    elif [ "$max_bounty" -ge 500 ]; then score=$((score + 4))
    else score=$((score + 2))
    fi
  else
    score=$((score + 5))
  fi
  
  local time_score=4
  [ "$estimated_hours" -le 2 ] && time_score=8
  [ "$estimated_hours" -le 4 ] && time_score=6
  score=$((score + time_score))
  
  local comp_score=3
  [ "$assets_count" -lt 10 ] && comp_score=4
  [ "$assets_count" -gt 50 ] && comp_score=1
  score=$((score + comp_score))
  [ "$score" -gt 25 ] && score=25
  
  echo "$score"
}

calculate_accessibility_score() {
  local has_github="$1"
  local repo_size="$2"
  local language="$3"
  local assets_count="$4"
  
  local score=0
  
  if [ "$has_github" = "true" ]; then
    score=$((score + 8))
  elif [ "$assets_count" -gt 0 ]; then
    score=$((score + 4))
  fi
  
  if [ "$repo_size" -gt 0 ] && [ "$repo_size" -lt 10000 ]; then
    score=$((score + 5))
  elif [ "$repo_size" -gt 50000 ]; then
    score=$((score + 2))
  else
    score=$((score + 3))
  fi
  
  case "$language" in
    "Python"|"Go"|"JavaScript"|"TypeScript") score=$((score + 4)) ;;
    "Rust"|"Java") score=$((score + 3)) ;;
    "C"|"C++") score=$((score + 2)) ;;
    *) score=$((score + 1)) ;;
  esac
  score=$((score + 2))
  [ "$score" -gt 20 ] && score=20
  
  echo "$score"
}

score_program() {
  local prog="$1"
  
  local name=$(echo "$prog" | jq -r '.name // ""')
  local platform=$(echo "$prog" | jq -r '.platform // ""')
  local language=$(echo "$prog" | jq -r '.language // ""')
  local repo_size=$(echo "$prog" | jq -r '.repo_size // 0')
  local max_bounty=$(echo "$prog" | jq -r '.max_bounty // "null"')
  local assets_count=$(echo "$prog" | jq -r '.assets_count // 0')
  local has_github=$(echo "$prog" | jq -r '.has_github_urls // false')
  
  [ -z "$language" ] || [ "$language" = "null" ] && language="unknown"
  [ -z "$repo_size" ] || [ "$repo_size" = "null" ] && repo_size=0
  
  local estimated_hours=4
  if [ "$repo_size" -gt 0 ] && [ "$repo_size" -lt 10000 ]; then
    estimated_hours=2
  elif [ "$repo_size" -gt 50000 ]; then
    estimated_hours=6
  fi
  
  local vuln_types="auth_bypass,idor,ssrf"
  local surface_type="web_api"
  
  local fit_score=$(calculate_fit_score "$language" "$vuln_types" "$surface_type")
  local track_score=$(calculate_track_record_score "$name" "$platform" "0")
  local roi_score=$(calculate_roi_score "$max_bounty" "$estimated_hours" "$assets_count")
  local access_score=$(calculate_accessibility_score "$has_github" "$repo_size" "$language" "$assets_count")
  
  local total_score=$((fit_score + track_score + roi_score + access_score))
  
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
      score_breakdown: {
        fit: $fit,
        track_record: $track,
        roi: $roi,
        accessibility: $access
      },
      metadata: {
        language: $language,
        repo_size: $repo_size,
        max_bounty: $max_bounty,
        assets_count: $assets_count,
        has_github: $has_github,
        estimated_hours: $estimated_hours
      }
    }'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
    while IFS= read -r prog; do
      score_program "$prog"
    done < "$1"
  else
    while IFS= read -r prog; do
      score_program "$prog"
    done
  fi
fi
