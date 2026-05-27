# Code Review Report — 2026-05-26
**Target:** Stripe (Smokescreen)
**Repo:** `stripe/smokescreen` (https://github.com/stripe/smokescreen)
**Language:** Go
**Commit:** 7d45971
**Ranking:** #1 (score 120.8) — offers_bounties=true, eff=92%, managed=true
**Scope:** Input parsing, auth logic, logging of sensitive data, trust boundary crossings

---

## Attack Surface Analysis

### 1. Input Parsing

#### 1.1 Host/Port Parsing
- `hostport.New()` and `hostport.NewWithScheme()` (`pkg/smokescreen/hostport/hostport.go:52-113`) parse proxy request targets from raw user input. Accepts hostnames, IPv4, IPv6 addresses, and FQDNs.
- `HasPort()` (hostport.go:116) uses `strings.LastIndex` to detect port presence — IPv6 addresses like `[::1]:8080` are properly handled via `net.SplitHostPort`, but raw IPv6 without brackets (e.g., `::1`) is first checked by `net.ParseIP` (hostport.go:81-85), which correctly identifies IPv6. Edge case: malformed IPv6 with port can produce unexpected parsing.
- `NormalizeHost()` (hostport.go:125-170) applies a custom IDNA profile with `StrictDomainName(false)`, allowing underscores in domain names. While permissive, the character whitelist (hostport.go:162) restricts to `[a-z0-9.-_]` — any character outside this set produces an error. No risk of injection into DNS resolution.

#### 1.2 X-Upstream-Https-Proxy Header (SSRF Risk)
- Client-supplied `X-Upstream-Https-Proxy` header (`smokescreen.go:1316`) is parsed by `url.Parse()` (`smokescreen.go:1363`) and the hostname is passed to ACL `Decide()` (`smokescreen.go:1388`). If a malicious upstream proxy is allowed by ACL, the attacker can chain SSRF through it.
- The parsed URL's hostname is validated only by the ACL — no validation of scheme, userinfo, or path. An upstream proxy URL like `https://attacker-controlled.com:8080` would be accepted if the domain matches an ACL rule's `allowed_external_proxies`.

#### 1.3 Trace/Role Headers
- `X-Smokescreen-Trace-ID` and `X-Smokescreen-Role` headers are accepted as input (`smokescreen.go:695`, `smokescreen.go:787-788`). These are stripped before forwarding to the destination, but are used internally for logging and role assignment. An attacker could inject arbitrary trace IDs to confuse log analysis.

#### 1.4 DNS Resolution
- `resolveTCPAddr()` (`smokescreen.go:329-363`) resolves hostnames via a configurable resolver. The resolver address is validated via `net.SplitHostPort` (`config.go:329`) but the DNS protocol itself is not authenticated — a MitM on the DNS channel can poison resolution and redirect traffic.
- IPv6 embedding detection (`smokescreen.go:270-272`) blocks NAT64, 6to4, and Teredo prefixes to prevent SSRF via IPv4 address embedding in IPv6 addresses.

#### 1.5 Rate Limiting
- Token bucket rate limiter (`rate_limiter.go:27-54`) protects against request floods. `MaxRequestBurst` defaults to `2x MaxRequestRate` when not set (`config.go:363`). No per-role or per-IP rate limiting — single global rate limit.
- `MaxConcurrentRequests` uses a channel-based semaphore (`rate_limiter.go:84-93`). When at capacity, returns 503 immediately — no queuing.

#### 1.6 Self-Connection Detection
- `addrIsLocalIp()` (`smokescreen.go:287-296`) and `InitializeSelfConnectionDetection()` (`config.go:410-428`) gather all local IPs at startup to prevent the proxy from connecting to itself — mitigates recursive proxy SSRF.

---

### 2. Auth Logic

#### 2.1 mTLS-Based Role Extraction
- `defaultRoleFromRequest()` (`main.go:16-24`) extracts the client role from the TLS client certificate's CommonName (CN). Requires TLS + client certificate. If TLS is missing or no certificate is provided, returns `MissingRoleError`.
- `getRole()` (`smokescreen.go:1236-1259`) wraps role extraction with `AllowMissingRole` fallback — when enabled, unauthenticated clients get an empty role and the default ACL rule.

#### 2.2 ACL Authorization
- `checkACLsForRequest()` (`smokescreen.go:1305-1435`) is the central authorization gate. Evaluates client role against `EgressACL.Decide()`.
- Three enforcement policies (`policy.go:22-26`):
  - **Open**: Allow all egress for this role (lowest security)
  - **Report**: Allow + log + metrics (monitoring mode)
  - **Enforce**: Deny unlisted domains (highest security)
- Global allow/deny lists (`acl.go:30-31`) override per-role rules.

#### 2.3 Domain Glob Matching
- `HostMatchesGlob()` (`acl.go:364-400`) matches hostnames against glob patterns. Normalizes to Punycode/ASCII before comparison. Wildcards only at prefix (`*.example.com`).
- Critical path: ACL decision in `checkACLsForRequest()` `smokescreen.go:1384-1401` — any error from `Decide()` results in a deny decision (fail-closed), which is correct.

#### 2.4 MITM Authorization
- When a CONNECT request matches MITM-configured domains (`acl.go:153-164`), the proxy intercepts TLS. The role from CONNECT is reused for subsequent HTTP requests over the MITM tunnel (`smokescreen.go:771-774`).
- `isConnectMitm` flag (`smokescreen.go:94`) prevents role reuse across non-MITM HTTP requests — mitigates a scenario where a client establishes a CONNECT tunnel with role A, then sends HTTP proxy requests through it impersonating role A.

#### 2.5 Role Caching Across MITM Requests
- MITM requests reuse the role from the CONNECT phase (`smokescreen.go:1339-1343`) but re-evaluate ACL against the new destination. This means a client with role A that opens a MITM tunnel to `allowed.example.com` cannot access `denied.example.com` through the same tunnel.

#### 2.6 Upstream Proxy Selection
- `selectUpstreamProxy()` (`smokescreen.go:1268-1278`) has a 3-tier priority: `UpstreamProxySelector` callback > client `X-Upstream-Https-Proxy` header > direct connection.
- **Trust concern**: The `UpstreamProxySelector` is a trusted callback that returns arbitrary URLs. The documentation warns "returned URLs are NOT validated" (`config.go:167`). A compromised or misconfigured selector can route traffic through attacker proxies.

#### 2.7 Missing: Token/Password Authentication
- Smokescreen has no built-in token or password authentication. The only authentication mechanism is mTLS client certificates. If `RoleFromRequest` is not configured, or if TLS is not used, all clients get the default ACL rule (or `AllowMissingRole` behavior).

---

### 3. Logging of Sensitive Data

#### 3.1 Standard Request Logging
- `newContext()` (`smokescreen.go:686-715`) creates a log entry with: request ID (`xid`), remote address, proxy type, requested host, start time, and trace ID. If TLS is available, logs X.509 certificate CN and OU.
- **CN/OU logging**: The client certificate's Common Name and Organizational Unit are logged in every request. These may identify the client service/role but are not secret. No sensitive claim information is exposed.

#### 3.2 Decision/ACL Logging
- `logProxy()` (`smokescreen.go:900-934`) logs decision reason, allow/deny status, enforce-would-deny, content length, DNS lookup time, and error messages.
- Deny reason messages can include resolved IP addresses and classification reasons (e.g., "Deny: Private Range"). No user secrets in standard deny messages.

#### 3.3 Detailed HTTP Logging (MITM)
- When `DetailedHttpLogs` is enabled for a MITM domain (`smokescreen.go:582-586`), the proxy logs: request URL, HTTP method, and request headers.
- **High severity**: `redactHeaders()` (`smokescreen.go:1437-1463`) redacts headers not in an explicit allowlist. However, if enabled without configuring `DetailedHttpLogsFullHeaders`, all headers are redacted to `[REDACTED]`. If configured too broadly, sensitive headers (Authorization, Cookie, X-API-Key) could leak to logs.

#### 3.4 Error/Diagnostic Logging
- `rejectResponse()` (`smokescreen.go:606-670`) can include the resolved address and classification reason in the response body. The `AdditionalErrorMessageOnDeny` config allows custom messages appended to deny responses.
- `logProxy()` logs errors at Error level, denies at Warn level, and allows at Info level. Error messages from DNS resolution, connection timeouts, and ACL failures are logged with full detail.

#### 3.5 Metrics Exposure
- StatsD and Prometheus metrics (`config.go:539-565`) expose: decision counts, resolver statistics, rate limit hits, tunnel concurrency, connection timing.
- Prometheus endpoint is on a separate listener (default: `0.0.0.0:9810/metrics`). If exposed on a shared interface without network isolation, ACL decision patterns can be deduced.

#### 3.6 Connection Tracking Logging
- `conntrack.InstrumentedConn` (`smokescreen.go:549`) wraps CONNECT connections and logs connection lifecycle events. At shutdown, all tracked connections are enumerated and closed (smokescreen.go:1221-1224).

#### 3.7 TLS Setup Logging
- `SetupCrls()` and `SetupTls()` (`config.go:475-632`) log CRL file paths, CA subject key IDs, and certificate loading status. File paths are not secrets, but the configuration reveals which CAs are trusted.

#### 3.8 Stats Socket
- Unix domain socket for connection tracking (`config.go:93-94`) with configurable file mode (default `0700`). Permissions restrict access to the owner, but any process on the host with access can read connection tracking data.

---

### 4. Trust Boundary Crossings

#### 4.1 Core Trust Boundary: ACL Decision
- The central trust boundary is `checkIfRequestShouldBeProxied()` (`smokescreen.go:1280-1303`). The ACL `Decide()` function determines whether a request crosses from the client's trust domain to an external host.
- ACL configuration is loaded from disk via YAML (`yaml_loader.go:49-72`). This is a trusted configuration file — any compromise of this file compromises all authorization decisions.

#### 4.2 DNS Resolution Boundary
- DNS resolution (`resolveTCPAddr` at smokescreen.go:329-363) crosses a trust boundary into the DNS system. A compromised or spoofed DNS resolver can redirect traffic to attacker-controlled IPs.
- The `Network` config (`"ip"`, `"ip4"`, `"ip6"`) controls which address families are used. If set to `"ip6"` and the destination only has IPv4, resolution fails — this can be a DoS vector if ACL allows a host but DNS can't resolve it.

#### 4.3 Upstream Proxy Boundary
- When `X-Upstream-Https-Proxy` or `UpstreamProxySelector` is configured, the proxy crosses into an upstream proxy's trust domain (`smokescreen.go:1268-1278`, `smokescreen.go:1316-1382`). The upstream proxy receives the full proxied request.
- **No validation of upstream proxy TLS**: The upstream proxy URL is used as-is. If an attacker can control the upstream proxy (or MitM the connection to it), they can intercept all proxied traffic.

#### 4.4 MITM TLS Interception Boundary
- When MITM is enabled for a domain (`smokescreen.go:987-1011`), Smokescreen generates TLS certificates on-the-fly using a configured CA (`config_loader.go:200-219`). This is a significant trust boundary crossing — Smokescreen acts as a trusted CA for intercepted connections.
- The MITM CA key material is loaded from disk and held in memory for the lifetime of the process. If the process memory is compromised, all intercepted TLS sessions can be decrypted.

#### 4.5 Filesystem Boundaries
- **ACL YAML file**: Read at startup (`yaml_loader.go:50`).
- **TLS certificates and keys**: Loaded from file paths (`config.go:602-631`).
- **CRL files**: Loaded and parsed (`config.go:476-537`).
- **Stats socket**: Unix domain socket created on the filesystem (`config.go:93`).
- All file reads occur at startup with the process's effective permissions. Hot-reload is not supported for most configuration (no SIGHUP handling for ACL/TLS reload).

#### 4.6 Metrics Endpoint Boundary
- Prometheus `/metrics` endpoint (`config.go:558-565`) is public by default (`0.0.0.0:9810`). No authentication on the metrics endpoint. While this is standard practice, it exposes internal decision-making data.
- StatsD metrics are sent to `127.0.0.1:8200` by default. If configured to a remote address, metrics data (including role names and decision counts) traverses the network.

#### 4.7 `RoleFromRequest` and `UpstreamProxySelector` Callbacks
- These are user-provided Go callbacks embedded in the proxy's process (`config.go:87,168`). They execute with the proxy's full authority. A vulnerability in these callbacks (e.g., code injection via malicious input) can compromise the entire proxy.
- `PostDecisionRequestHandler` (`config.go:150`) runs after ACL decisions. If an attacker can trigger an error in this handler, the request is denied — potential DoS vector.

#### 4.8 Healthcheck Endpoint
- Optional custom `http.Handler` for healthchecks (`config.go:97`). Executes within the proxy process. If implemented unsafely (e.g., reflecting input), can introduce vulnerabilities.

#### 4.9 Shutdown Signal Handling
- `runServer()` (`smokescreen.go:1132`) listens for `SIGUSR2`, `SIGTERM`, `SIGHUP` to trigger graceful shutdown. No SIGHUP configuration reload — signals only control lifecycle.

---

### Summary of Key Findings

| Severity | Finding | Location |
|----------|---------|----------|
| **High** | MITM CA key material held in memory for lifetime; process compromise decrypts all intercepted TLS | `config_loader.go:200-219` |
| **High** | `UpstreamProxySelector` callback returns arbitrary URLs without validation — misconfiguration or compromise enables traffic routing to attacker proxies | `config.go:163-168`, `smokescreen.go:1268-1278` |
| **Medium** | `DetailedHttpLogs` (MITM) can leak sensitive request headers (Authorization, Cookie) if allowlist is configured too broadly | `smokescreen.go:582-586`, `smokescreen.go:1437-1463` |
| **Medium** | No authentication on Prometheus metrics endpoint (default `0.0.0.0:9810`) — ACL decision patterns exposed | `config.go:558-565` |
| **Medium** | Client-supplied `X-Upstream-Https-Proxy` header parsed and used without scheme/credential validation | `smokescreen.go:1316-1382` |
| **Medium** | Role reuse across MITM CONNECT→HTTP relies on `isConnectMitm` boolean; logic error could allow role privilege escalation via non-MITM HTTP proxy | `smokescreen.go:93-94, 771-774, 1329-1351` |
| **Medium** | DNS resolver not authenticated — MitM on DNS channel can redirect traffic | `resolveTCPAddr` at `smokescreen.go:329-363` |
| **Low** | No per-role rate limiting — single global rate limit can be exhausted by one misbehaving client | `rate_limiter.go:57-74` |
| **Low** | `AllowMissingRole` with `open` ACL policy gives unauthenticated clients full egress access | `main.go:16-24`, `smokescreen.go:1249-1250` |
| **Low** | Stats socket accessible to any process on host with matching permissions (default `0700`) | `config.go:93-94, 241-247` |
| **Low** | Self-connection detection logs all local IPs at startup — minor information disclosure | `config.go:410-428` |
| **Low** | No hot-reload for ACL, TLS, or CRL configuration — requires process restart for changes | `yaml_loader.go:49-72`, `config.go:475-632` |
| **Info** | X.509 certificate CN and OU logged on every request — by design for role identification | `smokescreen.go:698-704` |
| **Info** | `postDecisionRequestHandler` error causes request denial — potential DoS if handler is unreliable | `smokescreen.go:816-821` |
