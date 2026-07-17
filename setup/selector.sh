#!/usr/bin/env bash
set -uo pipefail

# selector.sh - Intelligent target selector
PROFILE="${K_PROFILE:-memoria/k-profile.json}"

if [ ! -f "$PROFILE" ]; then
  echo "[selector] ERROR: K-profile not found at $PROFILE" >&2
  exit 1
fi

MAX_CONCURRENT=$(jq -r '.preferences.max_concurrent_targets // 5' "$PROFILE" 2>/dev/null)

select_targets() {
  local scored_file="$1"
  
  local all_programs=$(cat "$scored_file" 2>/dev/null || echo "[]")
  
  local eligible=$(echo "$all_programs" | jq '[.[] | select(.score_total >= 50 and .score_breakdown.fit >= 15)]')
  local eligible_count=$(echo "$eligible" | jq 'length')
  
  if [ "$eligible_count" -eq 0 ]; then
    echo "[]"
    return
  fi
  
  local sorted=$(echo "$eligible" | jq 'sort_by(-.score_total)')
  
  local selected="[]"
  
  local target1=$(echo "$sorted" | jq '.[0]')
  if [ "$(echo "$target1" | jq 'has("name")')" = "true" ]; then
    selected=$(echo "$selected" | jq --argjson t "$target1" '. + [$t]')
  fi
  
  local target2=$(echo "$sorted" | jq '[.[] | select(.name != null)] | sort_by(-.score_breakdown.roi) | .[0]')
  if [ "$(echo "$target2" | jq 'has("name")')" = "true" ]; then
    local t2_name=$(echo "$target2" | jq -r '.name')
    local already_selected=$(echo "$selected" | jq --arg n "$t2_name" '[.[] | select(.name == $n)] | length')
    if [ "$already_selected" -eq 0 ]; then
      selected=$(echo "$selected" | jq --argjson t "$target2" '. + [$t]')
    fi
  fi
  
  local target3=$(echo "$sorted" | jq '[.[] | select(.name != null)] | sort_by(-.score_breakdown.track_record) | .[0]')
  if [ "$(echo "$target3" | jq 'has("name")')" = "true" ]; then
    local t3_name=$(echo "$target3" | jq -r '.name')
    local already_selected=$(echo "$selected" | jq --arg n "$t3_name" '[.[] | select(.name == $n)] | length')
    if [ "$already_selected" -eq 0 ]; then
      selected=$(echo "$selected" | jq --argjson t "$target3" '. + [$t]')
    fi
  fi
  
  selected=$(echo "$selected" | jq --argjson max "$MAX_CONCURRENT" '.[:$max]')
  
  echo "$selected"
}

skills_for_language() {
  case "$1" in
    Go|Python)         echo "code-review-pygo,web-security,api-testing" ;;
    Rust)              echo "code-review-rust,web-security,api-testing" ;;
    Java)              echo "code-review-java,web-security,api-testing" ;;
    C|C++)             echo "code-review-c,code-fuzzing-c,web-security" ;;
    JavaScript|TypeScript) echo "web-security,api-testing,code-review-pygo" ;;
    *)                 echo "web-security,api-testing" ;;
  esac
}

generate_justification() {
  local target="$1"
  local rank="$2"
  
  local name=$(echo "$target" | jq -r '.name // ""')
  local platform=$(echo "$target" | jq -r '.platform // ""')
  local fit=$(echo "$target" | jq -r '.score_breakdown.fit // 0')
  local track=$(echo "$target" | jq -r '.score_breakdown.track_record // 0')
  local roi=$(echo "$target" | jq -r '.score_breakdown.roi // 0')
  local language=$(echo "$target" | jq -r '.metadata.language // "unknown"')
  local max_bounty=$(echo "$target" | jq -r '.metadata.max_bounty // "null"')
  local estimated_hours=$(echo "$target" | jq -r '.metadata.estimated_hours // 4')
  
  local skills_to_apply=$(skills_for_language "$language")
  local why=""
  local confidence=""
  
  if [ "$fit" -ge 20 ]; then
    why="Excelente fit con nuestras skills de $language"
    confidence="0.8"
  elif [ "$roi" -ge 18 ]; then
    why="Alto ROI potencial (bounty $max_bounty)"
    confidence="0.7"
  elif [ "$track" -ge 15 ]; then
    why="Buen track record en plataforma $platform"
    confidence="0.75"
  else
    why="Balance razonable entre fit, ROI y accesibilidad"
    confidence="0.65"
  fi
  
  local estimated_bounty="1000"
  if [ -n "$max_bounty" ] && [ "$max_bounty" != "null" ] && [ "$max_bounty" != "0" ]; then
    estimated_bounty="$max_bounty"
  fi
  
  local next_steps=""
  case "$platform" in
    yeswehack)
      next_steps='["Reconocimiento inicial","API enumeration","Test autenticación"]'
      ;;
    hackerone)
      next_steps='["Code review","Dynamic testing","PoC development"]'
      ;;
    *)
      next_steps='["Reconocimiento","Análisis de código","Testing"]'
      ;;
  esac
  
  jq -n \
    --argjson rank "$rank" \
    --arg name "$name" \
    --arg platform "$platform" \
    --argjson score "$target" \
    --arg why "$why" \
    --arg skills "$skills_to_apply" \
    --argjson hours "$estimated_hours" \
    --argjson bounty "$estimated_bounty" \
    --argjson confidence "$confidence" \
    --argjson next_steps "$next_steps" \
    '{
      rank: $rank,
      name: $name,
      platform: $platform,
      score_total: $score.score_total,
      score_breakdown: $score.score_breakdown,
      justification: {
        why: $why,
        skills_to_apply: ($skills | split(",")),
        estimated_hours: $hours,
        estimated_bounty: $bounty,
        confidence: $confidence
      },
      next_steps: $next_steps
    }'
}

main() {
  local input_file="${1:-/dev/stdin}"
  
  local selected=$(select_targets "$input_file")
  local selected_count=$(echo "$selected" | jq 'length')
  
  if [ "$selected_count" -eq 0 ]; then
    echo '{"selected_targets": [], "summary": "No eligible targets found"}'
    return
  fi
  
  local justified="[]"
  local rank=1
  while IFS= read -r target; do
    local justification=$(generate_justification "$target" "$rank")
    justified=$(echo "$justified" | jq --argjson j "$justification" '. + [$j]')
    rank=$((rank + 1))
  done < <(echo "$selected" | jq -c '.[]')
  
  local total_scored=$(jq 'length' "$input_file" 2>/dev/null || echo 0)
  local total_eligible=$(echo "$selected" | jq 'length')
  
  local summary=$(jq -n \
    --argjson scored "$total_scored" \
    --argjson eligible "$total_eligible" \
    --argjson selected "$total_eligible" \
    '{
      total_scored: $scored,
      total_eligible: $eligible,
      total_selected: $selected
    }')
  
  jq -n \
    --argjson targets "$justified" \
    --argjson summary "$summary" \
    '{
      selection_date: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
      selected_targets: $targets,
      summary: $summary
    }'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "${1:-}"
fi
