---
name: web-security
description: >-
  Use when analyzing web applications for OWASP Top 10 and common web
  vulnerabilities. Covers auth bypass, JWT attacks, CORS, GraphQL, SSRF,
  open redirect, XSS, CSRF, path traversal, and API security patterns.
  Consolidated from HackerOne, Bugcrowd, Intigriti, and YesWeHack research.
---

# Web Security Testing Playbook

## Authentication & Authorization

### JWT
- `alg: none` — server accepts unsigned tokens
- `kid` injection — path traversal / SQLi in key ID
- Weak HMAC secret — crack with hashcat
- Algorithm confusion — RS256 vs HS256 mismatch
- Missing `exp` / `iat` validation — replay tokens
- Check for `/jwk` or `/.well-known/jwks.json` exposure

### Session & Cookie Security
- No `HttpOnly` flag → XSS can steal cookie
- No `Secure` flag → leaked over HTTP
- No `SameSite` → CSRF via cross-site redirect
- Predictable session tokens (sequential, timestamp-based)

### OAuth / SSO
- Missing `state` parameter → CSRF on OAuth flow
- Redirect URI open redirect → token theft
- Token in URL fragment leaked via `Referer`
- No PKCE → authorization code interception

## Input Validation

### SSRF
- No host validation in `url.Parse(url)` + `http.Get(url)`
- Custom URL schemes (`file://`, `gopher://`, `dict://`)
- DNS rebinding bypass
- Bypass via URL obfuscation (`https://expected.com@attacker.com`)
- Timeout check: missing → indefinite connection hangs

### Path Traversal
- `startsWith(path)` + `readFile(path)` without realpath
- `path.join(user_input)` — `../` traversal
- Zip slip: filename in archive contains `../`
- Filename normalization: double encoding, UTF-8 tricks

### Open Redirect
- Header injection via `Location` / `Referer` controlled
- `next`, `returnTo`, `redirect` params without whitelist
- Bypass via `//attacker.com` (protocol-relative)

### Command Injection
- `exec.Command("sh", "-c", userInput)` — shell metacharacters
- Parameter injection via `--flag=value` style
- Blind via out-of-band DNS/HTTP exfiltration

## API Security

### GraphQL
- Introspection enabled → full schema leak
- Batching attacks → bypass rate limits
- Deep query nesting → DoS
- Missing auth on individual resolvers
- `__typename` brute force for hidden types

### CORS
- `Access-Control-Allow-Origin: null` — exploitable via data: URIs
- `Access-Control-Allow-Origin: *` with credentials
- Reflected origin (`Origin: https://evil.com`)
- Preflight bypass on simple requests

### Rate Limiting
- Missing limit on auth endpoints → brute force
- Missing on auto-creation → resource exhaustion
- Bypass via IP rotation (X-Forwarded-For)
- Bypass via parameter pollution

## Lecciones Aplicadas

### Body-based auditing (client-side limitaciones)
- No se pueden leer headers HTTP del target desde el browser
- CSP via meta tag ≠ CSP via header — falso negativo si solo miras meta
- WAF detection solo viable vía DNS NS + body patterns
- SRI check valioso pero ruidoso para CDNs propios

### Plugin Security
- `checkPluginRequest` vs `interPluginAuthorizationRequired` — el primero es bypassable
- Plugins con acceso directo a secretos del sistema (OAuth keys, webhook secrets)
- Authorization checks en plugins a menudo copypasteados sin adaptar por tenant
