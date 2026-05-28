---
name: api-testing
description: >-
  Use when testing REST, GraphQL, or gRPC APIs for security vulnerabilities.
  Covers IDOR, rate limiting, API key leakage, HTTP parameter pollution, and
  OpenAPI/Swagger analysis. For JWT, CORS, and GraphQL patterns see
  web-security skill. Based on Bugcrowd, HackerOne, Intigriti research.
---

# API Security Testing Playbook

## Reconnaissance Phase

### 1. Endpoint Discovery
```bash
# OpenAPI/Swagger
curl -s https://target.com/openapi.json
curl -s https://target.com/api/docs
curl -s https://target.com/swagger/v1/swagger.json

# Common paths
/api/
/v1/
/v2/
/graphql
/health
/status
/metrics
/debug
```

### 2. Technology Fingerprinting
- GraphQL: `/graphql` + `{"query":"{__schema{types{name}}}"}`
- REST: Check `Content-Type`, `X-Request-Id`, server headers
- Auth: Look for `Authorization: Bearer`, `X-API-Key`, cookies
- Rate limiting: Check `Retry-After`, `X-RateLimit-*` headers

## Vulnerability Classes

### 1. IDOR (Insecure Direct Object Reference)
```bash
# Pattern: numeric/guessable IDs
GET /api/users/123
GET /api/orders/ORDER-456
PUT /api/users/{id}/email  # change another user's email

# Test:
# 1. Create resource as user A
# 2. Access as user B using the same ID
# 3. Check for UUID vs sequential IDs (UUID harder but not impossible)
```

**Checklist:**
- UUIDs are NOT a fix — check server-side ownership validation
- Nested objects: `/api/groups/1/members/2` — test cross-group access
- Bulk endpoints: `/api/users?ids=1,2,3` — test visibility of others
- WebSocket messages with user IDs

### 2. Rate Limiting Abuse
```bash
# Test saturation
for i in $(seq 1 100); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    -X POST https://target.com/api/login \
    -H "Content-Type: application/json" \
    -d '{"email":"test@test.com","password":"wrong"}'
done

# Look for:
# - 429 Too Many Requests (rate limited)
# - 200 OK (NO rate limiting — finding!)
# - Different limits per endpoint (login vs search vs creation)
```

**High-value targets:**
- Login/forgot password (brute force)
- Account creation (DoS/user enumeration)
- OTP/SMS sending (financial abuse)
- Resource creation (storage DoS)
- Search endpoints (data scraping)

### 3. API Key / Token Leakage
```bash
# Check URLs
curl -s https://target.com/api/v1/users?api_key=test123

# Check query params for tokens
/api/export.csv?token=github_pat_...
/api/webhook?secret=...

# Check response bodies for keys
# Check error messages for stack traces with env vars
# Check auto-generated docs for hardcoded keys
```

### 7. HTTP Parameter Pollution
```bash
# Duplicate params
GET /api/search?user=admin&user=guest
POST /api/transfer?amount=100&amount=1

# Different cases
GET /api/admin/action?userId=123&userid=456

# Array confusion
GET /api/users?ids[]=1&ids[]=2  # PHP-style
GET /api/users?ids=1&ids=2       # Rails-style
```

## Methodology

### Phase 1: Passive Recon (no auth)
1. Map all endpoints from OpenAPI/docs
2. Check CORS on authenticated endpoints
3. Test rate limiting on public endpoints
4. Probe GraphQL introspection
5. Identify auth mechanisms

### Phase 2: Authenticated Testing
1. Create 2 accounts (user A, user B)
2. Test IDOR: create with A, access with B
3. Test privilege escalation (user → admin)
4. JWT attacks (alg:none, key confusion, kid injection)
5. Check for mass assignment
6. Test pagination limits (data scraping)

### Phase 3: Business Logic
1. Negative amounts / quantities
2. Race conditions (concurrent requests)
3. State transitions (skip steps in flow)
4. Coupon/discount abuse
5. Refund/credit cycling

## Tools & Commands

```bash
# curl-based testing (no deps)
# Test IDOR with parallel requests
for id in $(seq 1 100); do
  curl -s -H "Authorization: Bearer $TOKEN" \
    "https://target.com/api/users/$id" | jq '.email' &
done
wait

# Rate limiting test
ab -n 100 -c 10 -H "Authorization: Bearer $TOKEN" \
  https://target.com/api/endpoint

# JWT decode oneliner
alias jwt-dec='cut -d. -f2 | base64 -d 2>/dev/null | jq .'

# GraphQL introspection (with token)
gql_introspect() {
  curl -s "$1/graphql" -H "Content-Type: application/json" \
    -d '{"query":"{__schema{types{name fields{name args{name type{name}} type{name kind ofType{name kind}}}}}}"}'
}
```

## References
- Monzo internal-api.monzo.com: target identified for API testing (sesión 55)
- Auth0 nextjs-auth0 Open Redirect: inconsistent URL validation across endpoints (sesión 49)
- Doppler CLI Token Leak: sensitive data in debug responses (sesión 42)
- Firefox Relay DoS: auto-creation without rate limiting (sesión 32)
