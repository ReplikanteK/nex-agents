# Quick Scan Report: Doppler — 2026-09-18

**Date**: 2026-09-18
**Target**: Doppler (doppler.com)
**Platform**: HackerOne
**Score**: 66
**Scan Duration**: 25 minutes
**Analyst**: agent3

---

## Executive Summary

Doppler is a SecretOps Platform with an active HackerOne bug bounty ($250-$20,000). This scan focused on the MCP server (`@dopplerhq/mcp-server`) and Go CLI (`github.com/DopplerHQ/cli`) for new vulnerability classes not covered in previous scans.

**Finding**: One new finding with Medium severity related to arbitrary body parameter injection in the MCP server. Previous findings (DOPPLER_BASE_URL token theft, prompt injection bypass, open redirect) remain unpatched based on public repository state.

---

## Finding 1: Arbitrary Body Parameter Injection via Zod `passthrough()` in MCP Server

**Severity**: Medium (CVSS ~5.3)
**File**: `mcp-server/src/parser.ts:242`, `mcp-server/src/generator.ts:100-112`
**Component**: Doppler MCP Server (`@dopplerhq/mcp-server`)

### Description

The MCP server's OpenAPI-to-MCP tool generator uses Zod's `passthrough()` modifier when creating input schemas from the Doppler OpenAPI spec, and then blindly passes all non-path/query parameters directly to the API request body. This allows injection of arbitrary body parameters into any API call.

### Vulnerable Code

**Schema allows arbitrary properties** (`parser.ts:242`):
```typescript
return z.object(schemaFields).passthrough();
```

**All extra properties forwarded to API body** (`generator.ts:100-112`):
```typescript
if (tool.requestBody) {
  const contentType = Object.keys(tool.requestBody.content)[0];
  if (contentType === "application/json") {
    for (const [key, value] of Object.entries(input)) {
      const isPathOrQueryParam = key in pathParams || key in queryParams;
      if (!isPathOrQueryParam && value !== undefined) {
        bodyData[key] = value;
      }
    }
  }
}
```

### Attack Scenario

An attacker who can control MCP tool invocations (via prompt injection into an AI agent) can inject arbitrary body parameters:

1. **Privilege Escalation**: Inject fields like `admin: true` or `role: "owner"` into API calls that accept them.

2. **Parameter Pollution on `secrets-update`**: The API schema requires `project` and `config` in the body, but the MCP server also sends them as query parameters. An attacker can inject conflicting values:
   ```
   LLM calls: secrets_update({
     "project": "legitimate-project",    // scope check passes
     "config": "dev",
     "secrets": {"KEY": "stolen-value"},
     "project": "target-project"          // injected via passthrough
   })
   ```
   The API may use the body `project` to target a different project than what was scope-checked.

3. **Bypass `--read-only` Mode**: The read-only filter only applies at the MCP server level (filtering which tools are exposed). Since `passthrough()` allows arbitrary body properties, an LLM could potentially inject `method: "POST"` or similar fields if the API processes them.

### PoC

```typescript
// Demonstrates passthrough() allows arbitrary properties
import { z } from "zod";

// This is what the MCP server creates from the OpenAPI spec
const schema = z.object({
  project: z.string(),
  config: z.string(),
  secrets: z.record(z.string()).optional(),
}).passthrough();

// This validates successfully despite unexpected fields
const result = schema.parse({
  project: "my-project",
  config: "dev",
  secrets: {"KEY": "value"},
  // Arbitrary injected fields:
  admin: true,
  role: "owner",
  webhook_url: "https://evil.com/collect",
});
// result: { project: "my-project", config: "dev", secrets: {...},
//           admin: true, role: "owner", webhook_url: "https://evil.com/collect" }
```

### Impact

- **Scope Bypass**: MCP server validates `project`/`config` from input, but injected body parameters may override API behavior
- **Privilege Escalation**: If API accepts unexpected fields for authorization decisions
- **Data Exfiltration**: Injected webhook/callback URLs if API supports them
- **Severity is Medium** because:
  - Requires prompt injection into an AI agent using the MCP server
  - API may reject unknown parameters (depends on server implementation)
  - The MCP server's scope check is a client-side control only

### Recommendation

1. **Remove `passthrough()`** from the Zod schema creation — use strict object validation:
   ```typescript
   return z.object(schemaFields); // No .passthrough()
   ```

2. **Validate body parameters against the OpenAPI spec** before sending:
   ```typescript
   const allowedBodyKeys = new Set(
     Object.keys(tool.requestBody?.content?.['application/json']?.schema?.properties || {})
   );
   for (const [key, value] of Object.entries(input)) {
     if (!isPathOrQueryParam && !allowedBodyKeys.has(key) && value !== undefined) {
       throw new Error(`Unexpected parameter: ${key}`);
     }
   }
   ```

3. **Enforce scope on body parameters** — if `project`/`config` are in the body, validate them against the scope, not just the query params.

---

## Additional Observations (Not New, Unpatched)

### Previous Finding: MCP Prompt Injection Bypass (Critical, Report #2921905-equivalent)
The `confirm_access` tool is enforced only at the LLM level, not server-side. An attacker controlling LLM input can bypass the consent gate and perform write operations without user confirmation. (Documented in `scout-Doppler-MCP-prompt-injection.md`)

### Previous Finding: Open Redirect via `authUrl` (Medium)
The MCP server displays `auth_url` from the API response without validation. (Documented in `codereview-doppler-20260807.md`)

### Previous Finding: No Response Body Size Limit (Low)
`ioutil.ReadAll(response.Body)` without size limit in Go CLI. (Documented in `codereview-doppler-20260807.md`)

---

## Conclusion

The MCP server's use of Zod `passthrough()` creates a parameter injection vulnerability that could be exploited via prompt injection to bypass scope restrictions or inject unexpected API parameters. While the practical impact depends on server-side API behavior, this represents a defense-in-depth failure in the MCP server's input validation layer.

**Verdict**: Finding 1 is reportable as a Medium-severity vulnerability. The prompt injection bypass (previous finding) remains the highest-priority issue but was already documented.

---

*Report generated: 2026-09-18 by agent3*
