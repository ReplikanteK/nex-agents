#!/usr/bin/env bash
set -uo pipefail

# filters.sh - Hard filters for target selection
# Input: JSON program data from stdin or file argument
# Output: JSON with filter results

PROFILE="${K_PROFILE:-memoria/k-profile.json}"

# Load K profile
if [ ! -f "$PROFILE" ]; then
  echo "[filters] ERROR: K-profile not found at $PROFILE" >&2
  exit 1
fi

# Filter 1: Scope verification
check_scope() {
  local name="$1"
  local platform="$2"
  local assets="$3"
  
  local name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
  
  if echo "$name_lower" | grep -qiE '(government|military|gov\.|army|navy|air.force|defense|ministry)'; then
    echo "false:government_program"
    return
  fi
  
  if echo "$assets" | grep -qiE '(only.*critical|only.*rce|only.*sqli)'; then
    echo "false:restrictive_scope"
    return
  fi
  
  echo "true:"
}

# Filter 2: Duplicate detection
check_duplicates() {
  local name="$1"
  local platform="$2"
  echo "true:"
}

# Filter 3: Security vs functional program
check_security_program() {
  local name="$1"
  local platform="$2"
  local offers_bounties="$3"
  local description="$4"
  
  local desc_lower=$(echo "$description" | tr '[:upper:]' '[:lower:]')
  
  if echo "$desc_lower" | grep -qiE '(no.*bounty.*for|not.*eligible|informational.*only)'; then
    if [ "$offers_bounties" = "false" ]; then
      echo "false:no_bounties"
      return
    fi
  fi
  
  echo "true:"
}

# Filter 4: Account status
check_account_status() {
  local platform="$1"
  
  local can_submit=$(jq -r --arg p "$platform" '.track_record.platform_status[$p].can_submit // false' "$PROFILE" 2>/dev/null)
  
  if [ "$can_submit" = "true" ]; then
    echo "true:"
  else
    local reason=""
    case "$platform" in
      hackerone)
        reason=$(jq -r '.track_record.platform_status.hackerone.cooldown_until // "signal_score_low"' "$PROFILE" 2>/dev/null)
        ;;
      bugcrowd)
        reason=$(jq -r '.track_record.platform_status.bugcrowd.cooldown_until // "suspended"' "$PROFILE" 2>/dev/null)
        ;;
      intigriti)
        reason=$(jq -r '.track_record.platform_status.intigriti.cooldown_until // "limit_reached"' "$PROFILE" 2>/dev/null)
        ;;
    esac
    echo "false:account_$reason"
  fi
}

# Filter 5: Saturation check
check_saturation() {
  local name="$1"
  local platform="$2"
  local assets_count="$3"
  
  if [ "$assets_count" -gt 50 ]; then
    echo "false:large_program_saturated"
    return
  fi
  
  local name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
  if echo "$name_lower" | grep -qiE '(lightspark|uber|airbnb|shopify)'; then
    echo "false:known_saturated"
    return
  fi
  
  echo "true:"
}

# Filter 6: Minimum bounty check
check_min_bounty() {
  local max_bounty="$1"
  local min_required=$(jq -r '.preferences.min_bounty_usd // 500' "$PROFILE" 2>/dev/null)
  
  if [ -z "$max_bounty" ] || [ "$max_bounty" = "null" ] || [ "$max_bounty" = "0" ]; then
    echo "true:unknown_bounty"
    return
  fi
  
  if [ "$max_bounty" -ge "$min_required" ]; then
    echo "true:"
  else
    echo "false:bounty_too_low_${max_bounty}"
  fi
}

# Main filter function
apply_filters() {
  local prog="$1"
  
  local name=$(echo "$prog" | jq -r '.name // ""')
  local platform=$(echo "$prog" | jq -r '.platform // ""')
  local offers_bounties=$(echo "$prog" | jq -r '.offers_bounties // false')
  local assets_count=$(echo "$prog" | jq -r '.assets_count // 0')
  local max_bounty=$(echo "$prog" | jq -r '.max_bounty // "null"')
  local description=$(echo "$prog" | jq -r '.description // ""')
  local assets=$(echo "$prog" | jq -c '.github_urls // []')
  
  local scope_result=$(check_scope "$name" "$platform" "$assets")
  local dup_result=$(check_duplicates "$name" "$platform")
  local security_result=$(check_security_program "$name" "$platform" "$offers_bounties" "$description")
  local account_result=$(check_account_status "$platform")
  local saturation_result=$(check_saturation "$name" "$platform" "$assets_count")
  local bounty_result=$(check_min_bounty "$max_bounty")
  
  local scope_ok=$(echo "$scope_result" | cut -d: -f1)
  local scope_reason=$(echo "$scope_result" | cut -d: -f2-)
  local dup_ok=$(echo "$dup_result" | cut -d: -f1)
  local dup_reason=$(echo "$dup_result" | cut -d: -f2-)
  local security_ok=$(echo "$security_result" | cut -d: -f1)
  local security_reason=$(echo "$security_result" | cut -d: -f2-)
  local account_ok=$(echo "$account_result" | cut -d: -f1)
  local account_reason=$(echo "$account_result" | cut -d: -f2-)
  local saturation_ok=$(echo "$saturation_result" | cut -d: -f1)
  local saturation_reason=$(echo "$saturation_result" | cut -d: -f2-)
  local bounty_ok=$(echo "$bounty_result" | cut -d: -f1)
  local bounty_reason=$(echo "$bounty_result" | cut -d: -f2-)
  
  local all_passed="true"
  local rejection_reason=""
  
  if [ "$scope_ok" != "true" ]; then
    all_passed="false"
    rejection_reason="scope:$scope_reason"
  elif [ "$account_ok" != "true" ]; then
    all_passed="false"
    rejection_reason="account:$account_reason"
  elif [ "$security_ok" != "true" ]; then
    all_passed="false"
    rejection_reason="security:$security_reason"
  elif [ "$saturation_ok" != "true" ]; then
    all_passed="false"
    rejection_reason="saturation:$saturation_reason"
  elif [ "$bounty_ok" != "true" ]; then
    all_passed="false"
    rejection_reason="bounty:$bounty_reason"
  fi
  
  jq -n \
    --arg name "$name" \
    --arg platform "$platform" \
    --argjson passed "$all_passed" \
    --arg reason "$rejection_reason" \
    --arg scope_ok "$scope_ok" \
    --arg scope_reason "$scope_reason" \
    --arg dup_ok "$dup_ok" \
    --arg dup_reason "$dup_reason" \
    --arg security_ok "$security_ok" \
    --arg security_reason "$security_reason" \
    --arg account_ok "$account_ok" \
    --arg account_reason "$account_reason" \
    --arg saturation_ok "$saturation_ok" \
    --arg saturation_reason "$saturation_reason" \
    --arg bounty_ok "$bounty_ok" \
    --arg bounty_reason "$bounty_reason" \
    '{
      name: $name,
      platform: $platform,
      passed_all: $passed,
      rejection_reason: $reason,
      filters: {
        scope: {ok: ($scope_ok == "true"), reason: $scope_reason},
        duplicates: {ok: ($dup_ok == "true"), reason: $dup_reason},
        security: {ok: ($security_ok == "true"), reason: $security_reason},
        account: {ok: ($account_ok == "true"), reason: $account_reason},
        saturation: {ok: ($saturation_ok == "true"), reason: $saturation_reason},
        bounty: {ok: ($bounty_ok == "true"), reason: $bounty_reason}
      }
    }'
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
    while IFS= read -r prog; do
      apply_filters "$prog"
    done < "$1"
  else
    while IFS= read -r prog; do
      apply_filters "$prog"
    done
  fi
fi
