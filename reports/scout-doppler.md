# Doppler Security Reconnaissance Report
**Date**: 2026-07-12  
**Target**: Doppler (HackerOne)  
**Score**: 66  
**Language**: Go  

## Scope Verification
- **In-scope assets**:
  - https://github.com/DopplerHQ/cli (source code)
  - api.doppler.com (REST API)
  - dashboard.doppler.com (web dashboard)
  - share.doppler.com (secret sharing)
  - doppler.team (internal team access)
  - doppler (binary)

- **Out-of-scope assets**:
  - docs.doppler.com
  - support.doppler.com
  - community.doppler.com
  - https://github.com/DopplerHQ/awesome-bots
  - http://calendly.com/doppler/enterprise

## Reconnaissance Summary

### api.doppler.com
- REST API with Bearer token authentication.
- OpenAPI specification available (not public).
- Endpoints for managing projects, configs, secrets, integrations, etc.
- Rate limits enforced per plan.
- TLS enforced; option to disable verification via CLI flag (`--no-verify-tls`).

### dashboard.doppler.com
- React SPA with server-side rendering.
- Cloudflare protection, reCAPTCHA, Bugsnag.
- CSRF token in hydration data.
- Cookie-based session (`usrs`) with HttpOnly, Secure, SameSite=Lax.
- CSP header with nonce for inline scripts.

### share.doppler.com
- End-to-end encrypted secret sharing.
- Client-side encryption (shared-crypto.js).
- CSRF cookie with HttpOnly, Secure, SameSite=Strict.
- Slack integration note: secrets shared through Slack are encrypted server-side.
- CSP header restrictive.

### doppler.team
- Cloudflare Access login page (Google OAuth).
- Protected internal domain; likely not testable.

## Code Review Findings (CLI)

### Crypto Implementation
- AES-256-GCM with PBKDF2 (500k rounds) for fallback file encryption.
- Salt and IV random per encryption.
- No obvious weaknesses.

### Configuration & Keyring
- Tokens stored in system keyring via go-keyring.
- Config file permissions 0600.
- No plaintext token storage.

### HTTP Client
- TLS verification enabled by default.
- Custom DNS resolver support.
- Retry logic with exponential backoff.
- No SSRF vulnerabilities observed.

### Command Execution
- `doppler run` executes user-provided command via shell.
- Injection risk is user-responsible (expected behavior).
- Secrets injected as environment variables, not command arguments.

### Path Traversal
- Fallback file path validated; no directory traversal.

### Potential Issues
1. **TLS verification bypass**: `--no-verify-tls` flag disables certificate verification. Could be exploited in MITM attacks if user is tricked.
2. **Custom API host**: Users can set arbitrary API host, potentially leaking tokens to attacker-controlled server if misconfigured.
3. **Slack integration encryption**: Server-side encryption for Slack shares may have weaker security than client-side E2E encryption.

## Dynamic Testing
- Unauthenticated API requests return generic error message with documentation link.
- No sensitive information leakage observed.

## Recommendations
- Ensure users understand risks of `--no-verify-tls` and custom API host.
- Review Slack integration encryption implementation.
- Consider adding warnings for HTTP (non-TLS) API hosts.

## Conclusion
No critical vulnerabilities identified. The codebase follows security best practices. The identified issues are configuration-related and require user interaction. Further testing with authenticated access may reveal additional issues.