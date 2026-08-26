# Doppler Quick Scan Report

**Date**: 2026-08-26
**Target**: Doppler (HackerOne)
**Score**: 66
**Scanner**: agent3

## Executive Summary

Reconnaissance completed on Doppler's secrets management platform. The target has a mature security posture with proper authentication, CORS, CSP, and HSTS configurations. No confirmed vulnerability with working PoC found during this quick scan.

## Attack Surface

| Asset | Type | Status |
|-------|------|--------|
| api.doppler.com | API | Active |
| dashboard.doppler.com | Web App | Active |
| share.doppler.com | Share Links | Active |
| docs.doppler.com | Documentation | Active |

## Findings

### 1. Unauthenticated Share Link Creation (Informational)

**Endpoint**: `POST /v1/share/secrets/plain`
**Authentication**: Not required (despite OpenAPI spec indicating basic auth)

**PoC**:
```bash
curl -X POST "https://api.doppler.com/v1/share/secrets/plain" \
  -H "Content-Type: application/json" \
  -d '{"secret": "test123", "expire_views": 1, "expire_days": 1}'
```

**Response**:
```json
{
  "url": "https://share.doppler.com/s/a0l22mp2xi4sefpcekfremw2gokv8rngdlcm8ehb",
  "authenticated_url": "https://share.doppler.com/s/a0l22mp2xi4sefpcekfremw2gokv8rngdlcm8ehb#702c3b2d96966ad30155e6c67ca326de6d1cf20a9af047cebd33f229904f39f8",
  "password": "702c3b2d96966ad30155e6c67ca326de6d1cf20a9af047cebd33f229904f39f8",
  "success": true
}
```

**Analysis**:
- Share IDs are random (not sequential), preventing enumeration
- This appears to be by design - share links are meant to be public
- **Not a vulnerability** - this is intended functionality

### 2. Security Controls Verified (Positive)

| Control | Status | Details |
|---------|--------|---------|
| CORS | ✅ Properly configured | Fixed to `https://docs.doppler.com` |
| CSP | ✅ Present | Comprehensive policy with nonce-based script loading |
| HSTS | ✅ Enabled | `max-age=31536000; includeSubDomains; preload` |
| X-Frame-Options | ✅ Present | `SAMEORIGIN` |
| Authentication | ✅ Required | All sensitive endpoints return 401 without valid token |
| Error Messages | ✅ Minimal | No verbose errors leaking information |

### 3. Rate Limiting

| Endpoint | Rate Limit |
|----------|------------|
| API Reads | 240-480/min (plan dependent) |
| Secret Reads | 120-480/min |
| API Writes | 60-240/min |

Rate limit headers are properly returned:
- `x-ratelimit-limit`
- `x-ratelimit-remaining`
- `x-ratelimit-reset`

## Past Vulnerabilities (Disclosed)

| Report | Title | Severity | Bounty |
|--------|-------|----------|--------|
| 2801036 | Availability Impact from Project Name Vulnerability | Low | $250 |
| 2418210 | Broken Link Takeover | Low | — |
| 2399386 | GitHub App Takeover | Low | — |
| 2921905 | WAF Bypass & Unicode Handling | None | — |

## Recommendations for Further Testing

1. **Service Token Scope Bypass** - Test if service tokens can access resources outside their intended project/config scope
2. **IDOR on Project/Config Endpoints** - With valid tokens, test for cross-tenant access
3. **Webhook URL Validation** - Test SSRF potential via webhook configuration (requires valid auth)
4. **Slack Integration Passphrase** - The Slack flow has server-generated passphrases; test for predictability
5. **MCP Server Security** - New feature; test for authentication/authorization issues

## Conclusion

Doppler has a mature security posture. The quick scan did not find a confirmed vulnerability with working PoC. The unauthenticated share link creation is by design and not a security issue.

**Recommendation**: Deeper testing with valid authentication tokens is required to find authorization bypass or IDOR vulnerabilities. Consider creating a test account to explore the full API surface.
