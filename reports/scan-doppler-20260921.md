# Doppler Quick Scan - 2026-09-21

## Target
- **Name**: Doppler
- **Platform**: HackerOne
- **Score**: 66
- **Time**: ~25 minutes

## Findings

### 1. Unauthenticated Egress IP Disclosure (Low)
- **Endpoint**: `GET https://api.doppler.com/_/outbound-ips`
- **PoC**: `curl https://api.doppler.com/_/outbound-ips`
- **Response**: `{"ips":["34.72.116.160","35.225.173.138","34.41.242.137","34.121.232.141","34.30.81.34","34.72.233.184","34.136.103.169","34.27.178.190"],"success":true}`
- **Impact**: Exposes Doppler's egress IPs without authentication. No CORS headers, cross-origin readable. Could aid IP allowlist bypass.
- **Verdict**: Low severity, likely informative/WN

### 2. No Rate Limiting on Auth Endpoints (Low)
- **PoC**: 30 rapid requests to `POST /v3/auth/cli/authorize` — all returned 401, no 429
- **Impact**: Could enable brute force attacks (limited without valid usernames)
- **Verdict**: Low severity

### 3. JS Source Maps Accessible in Production (Info)
- **PoC**: `curl -s -o /dev/null -w "%{http_code}" "https://dashboard.doppler.com/public/assets/minimal-CJNhqNIY.js.map"` returns 200
- **Impact**: Exposes original source code and internal logic
- **Verdict**: Informational

## What Was Tested (No Vulnerability Found)
- API authorization — all endpoints require auth
- CORS policy — properly restricted to `docs.doppler.com`
- Error handling — generic messages, no info leak
- Share feature — properly protected
- CLI crypto — AES-256-GCM with PBKDF2, secure
- CLI keyring storage — properly implemented
- HTTP methods — consistent enforcement
- Hidden API endpoints — none found
- Subdomains — staging/dev/test/beta/admin not accessible

## Verdict
Doppler has strong security posture. Findings are low severity. Not worth submitting as bug bounty report — would likely be marked informative/WN.

## Recommendation
Skip this target. Move to higher-value targets with weaker security posture.
