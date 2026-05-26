# Code Review Report — 2026-05-26
**Target:** Supabase (Auth Service)
**Repo:** `supabase/auth` (https://github.com/supabase/auth)
**Language:** Go
**Commit:** latest HEAD as of 2026-05-26
**Scope:** Input parsing, auth logic, logging of sensitive data, trust boundary crossings

---

## Attack Surface Analysis

### 1. Input Parsing

#### 1.1 JSON Body Parsing
- `retrieveRequestParams` (internal/api/helpers.go:84) unmarshals JSON into generic structs via `json.Unmarshal`. No schema validation beyond Go type system — extra fields in JSON are silently accepted.
- `SignupParams`, `PasswordGrantParams`, `UserUpdateParams` accept arbitrary `map[string]interface{}` fields (e.g., `Data`, `UserMetaData`), which flow directly into the database and JWT claims.
- Request body limited to 1MB (`internal/api/api.go:178`) via `limitRequestBody`, preventing memory exhaustion.

#### 1.2 Email/Phone Validation
- Email validation is done via `validateEmail()` before signup but is not applied to login or token endpoints — `FindUserByEmailAndAudience` does case-insensitive matching but no format validation.
- Phone number formatting via `formatPhoneNumber()` (`token.go:103`) is applied in password grant but not consistently across all phone-related handlers.

#### 1.3 Redirect URL Validation (Open Redirect Risk)
- `GetReferrer` / `getRedirectTo` (internal/utilities/request.go:75-89) reads `redirect_to` header/param and falls back to `Referer` header, validated against a `URIAllowListMap`.
- Validation accepts loopback IPs (request.go:119) but **blocks decimal IP addresses** (request.go:115-117) — an improvement over common patterns, but allowlist misconfigurations could still allow open redirect.
- OAuth callback errors are returned in URL fragments (external.go:808-823), which can leak error details to third parties via `Referer` headers.

#### 1.4 Host Header Validation
- `isValidExternalHost` middleware (middleware.go:278) checks `X-Forwarded-Host` and `Host` against `config.Mailer.ExternalHosts`. If no allowlist is configured, defaults to `config.API.ExternalURL`. If neither matches, a log message is written but the request proceeds — this can lead to host confusion attacks if the external URL is misconfigured.

#### 1.5 Rate Limiting
- `performRateLimiting` (middleware.go:123) uses `sbff.GetIPAddress()` first, falls back to a configurable rate limit header. If no header value is present, rate limiting is silently disabled with a warning log (middleware.go:83-86). This means misconfigured deployments can bypass rate limits.

---

### 2. Auth Logic

#### 2.1 JWT Authentication
- `requireAuthentication` (internal/api/auth.go:20-36): Bearer token extracted via regex `(?i)^bearer (\S+$)` (api.go:37). JWT parsed with configurable valid signing methods.
- Key selection uses `kid` header (auth.go:83-94) — falls back to HMAC secret if alg is HS256 and no kid matches. **Attack vector**: an attacker who obtains or guesses a `kid` that maps to a known public key could forge tokens if the corresponding private key is compromised or if JWKS endpoint leaks keys.
- `parseJWTClaims` (auth.go:77-110): JWT validation uses `jwt.NewParser` with `WithValidMethods` — this prevents algorithm confusion attacks (e.g., RS256→HS256).
- No built-in token revocation except through session/refresh token rotation — access tokens are valid until expiry.

#### 2.2 Admin Authentication
- `requireAdminCredentials` (middleware.go:187-199) extracts bearer token and calls `requireAdmin`, which checks `claims.Role` against `config.JWT.AdminRoles` (auth.go:54-64). **Issue**: admin roles are derived solely from the JWT `role` claim — if an access token is leaked or forged with an admin role, no additional verification (e.g., IP allowlist, MFA) is performed.

#### 2.3 Password Authentication
- `ResourceOwnerPasswordGrant` (token.go:71-212): Password validated via `user.Authenticate()` which uses `crypto.CompareHashAndPassword` — supports bcrypt, argon2, and Firebase Scrypt.
- `MaxPasswordLength = 72` (password.go:13): passwords longer than 72 chars are rejected before bcrypt truncation — good.
- HIBP integration is optional (fail-open by default, configurable to fail-closed in password.go:56-68) — pwned password check can be bypassed if HIBP is unreachable.
- Weak password error returns specific reasons (`pwned`, `length`, `characters`) — this information disclosure helps attackers refine password guessing.

#### 2.4 Refresh Token Rotation
- Refresh token rotation supports v1 (database-backed) and v2 (HMAC-signed) tokens (tokens/service.go).
- `RefreshTokenReuseInterval` (configurable) allows brief reuse (service.go:389-391) for UX but opens a window for token replay.
- Counter-based detection for concurrent refreshes (service.go:492-537) handles "fail-to-save" and "concurrent-refresh" scenarios gracefully.
- **Attack vector**: If `RefreshTokenRotationEnabled` is false AND `RefreshTokenAllowReuse` is true, refresh tokens can be replayed indefinitely.

#### 2.5 MFA / Factor Verification
- Factors (TOTP, Phone, WebAuthn) can be enrolled and verified. AAL (Authenticator Assurance Level) tracked per session.
- Session downgrade from AAL2→AAL1 is prevented via `session.CalculateAALAndAMR()`.
- MFA challenge has configurable expiry (default 300s).

#### 2.6 OAuth / SSO / SAML
- OAuth client authentication supports multiple methods (`client_secret_basic`, `client_secret_post`, `none`). `token_endpoint_auth_method` is configurable per client.
- SAML ACS endpoint processes arbitrary SAML assertions — relies on `SAMLEnabled` guard but assertion validation details are in `samlacs.go` / `samlassertion.go`.
- Custom OAuth/OIDC providers store encrypted secrets in the database — decrypted at runtime (`loadCustomProvider`, external.go:722).

---

### 3. Logging of Sensitive Data

#### 3.1 Request Logging
- `request-logger.go:48-68`: Logs `method`, `path`, `remote_addr`, `referer`, `grant_type` (for `/token`). No request body or headers (auth tokens) are logged in standard logs — good.
- User-Agent and IP address are stored in sessions (tokens/service.go:609-621) — this is intended audit data.

#### 3.2 SQL / Database Logging
- `logging.go:94-124`: SQL logging can include query arguments when `LOG_SQL_ALL` is configured. If enabled, sensitive data (passwords, tokens, emails) in SQL queries could appear in logs.
- Logging configuration is read from environment — if debug SQL logging is inadvertently enabled in production, it leaks query data.

#### 3.3 Error Logging
- `HandleResponseError` (errors.go:80-218) logs error details with `WithError()`. For 5xx errors, `errorID` is logged. Internal error messages are logged via `WithInternalMessage()` but not sent to the client.
- WeakPasswordError returns specific reasons (`reasons` field) to the API client — this is by design but leaks password policy violation details.

#### 3.4 Audit Logs
- Audit log entries are stored in the database with user ID, action, and metadata (including provider type, IP, etc.). These are intended for security auditing but represent a sensitive data store that must be protected.
- `NewAuditLogEntry` is called for login, signup, token refresh, and other auth events — the metadata map can include arbitrary keys.

#### 3.5 Headers
- Custom response headers `sb-auth-user-id`, `sb-auth-session-id`, `sb-auth-refresh-token-prefix`, `sb-auth-refresh-token-counter` are set in responses. The `sb-auth-refresh-token-prefix` header leaks the first 5 characters of the refresh token (tokens/service.go:468) — a minor information disclosure.

---

### 4. Trust Boundary Crossings

#### 4.1 External OAuth Providers
- OAuth callback (external.go:131-289) processes data from external providers (Google, GitHub, Apple, etc.) and creates/links user accounts based on provider claims.
- `createAccountFromExternalIdentity` (external.go:292-447) handles 4 decision paths: `LinkAccount`, `CreateAccount`, `AccountExists`, `MultipleAccounts`. A misconfigured linking domain could allow account takeover via provider email mismatch.
- `processInvite` (external.go:449-515) checks invited email against provider emails — if no match, returns an error that includes the list of provider emails in the internal message (external.go:471).

#### 4.2 Webhook Hooks
- `hookshttp.go` and `hookspgfunc.go` execute custom hooks (HTTP and Postgres function) that can be triggered on auth events.
- `CustomAccessToken` hook (tokens/service.go:719-737) allows an external HTTP call or Postgres function to modify JWT claims. Claims are validated against a JSON schema (`MinimumViableTokenSchema`) — good, but the schema allows `additionalProperties: true` for `app_metadata` and `user_metadata`, meaning arbitrary data can be injected into tokens.
- `PasswordVerificationAttempt` hook (token.go:154-176) can reject logins and force logout — a hook failure or malicious hook could cause mass account lockout.

#### 4.3 SAML
- SAML ACS endpoint accepts POST with SAMLResponse — this is a classic trust boundary crossing. Assertion signature verification is critical. The SAML implementation (`samlacs.go`, `samlassertion.go`) must properly validate signatures, audience, and timestamps.
- SAML relay state includes flow state ID — if an attacker can obtain a valid relay state, they may be able to replay SAML responses.

#### 4.4 Custom OAuth Providers
- `loadCustomProvider` (external.go:689-797) loads provider configurations from the database, decrypts client secrets, and creates OAuth/OIDC provider instances.
- Custom providers support `AcceptableClientIDs` — a security measure to verify the issuer's token audience, but this is optional and provider-specific.

#### 4.5 Rate Limiting Trust Boundary
- Rate limiting relies on `sbff.GetIPAddress()` (internal/sbff/) which parses the `Sb-Forwarded-For` header. If this header can be spoofed (e.g., if the service is exposed directly without a proxy stripping the header), rate limits can be bypassed.

#### 4.6 OpenID Connect Discovery
- `/.well-known/openid-configuration` and `/.well-known/jwks.json` endpoints are public (api.go:198-204). The JWKS endpoint exposes public signing keys. While this is standard OIDC behavior, it means anyone can verify JWT signatures — this is by design but means leaked tokens can be validated offline.

---

## Summary of Key Findings

| Severity | Finding | Location |
|----------|---------|----------|
| High | Admin role derived solely from JWT claim — no additional verification | `internal/api/auth.go:54-64` |
| High | Custom Access Token hook allows arbitrary claim injection (schema limited but metadata objects are open) | `internal/tokens/service.go:719-737` |
| Medium | SQL debug logging can leak sensitive data when `LOG_SQL_ALL` is enabled | `internal/observability/logging.go:94-124` |
| Medium | Open redirect possible if URI allowlist is misconfigured | `internal/utilities/request.go:75-89` |
| Medium | Rate limiting silently disabled when header is missing | `internal/api/middleware.go:83-86` |
| Medium | `sb-auth-refresh-token-prefix` header leaks 5 chars of refresh token | `internal/tokens/service.go:468` |
| Medium | Refresh token reuse interval creates brief replay window | `internal/tokens/service.go:389-391` |
| Low | Host header validation logs but does not reject unlisted hosts | `internal/api/middleware.go:319-343` |
| Low | Weak password reasons leaked to client | `internal/api/password.go:70-74` |
| Low | OAuth callback errors leak via URL fragments | `internal/api/external.go:808-823` |
| Low | Extra JSON fields silently accepted in request bodies | `internal/api/helpers.go:84-95` |
