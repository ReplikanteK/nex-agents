# Recon Report: Doppler (HackerOne Target)

## Summary

| Attribute | Details |
|---|---|
| **Product** | Secrets Management / SecretOps Platform |
| **Company** | Doppler (founded 2018, HQ San Francisco, CA) |
| **Domain** | doppler.com |
| **HackerOne Program** | [hackerone.com/doppler](https://hackerone.com/doppler) |
| **Bounty Range** | $250 (Low) – $10,000 (Critical) |
| **Total Bounties Paid** | ~$36,375 |
| **Compliance** | SOC 2 Type II, ISO 27001, GDPR, HIPAA, PCI DSS |
| **Employees** | 11-50 |

---

## In-Scope Assets

| Target | Type | Testing Focus |
|---|---|---|
| `api.doppler.com` | URL | All v3 REST endpoints, auth bypass, IDOR, rate limiting |
| `dashboard.doppler.com` | URL | XSS, CSRF, privilege escalation, SSRF, OAuth misconfig |
| `share.doppler.com` | URL | Secret sharing link security, E2E encryption flaws |
| `doppler.team` | URL | Team management, invitation bypass, role escalation |
| `github.com/DopplerHQ/cli` | Source Code | Hardcoded secrets, insecure crypto, command injection |

---

## Technology Stack

| Layer | Technology |
|---|---|
| **Web Framework** | Next.js 14.2.35 / React |
| **API** | RESTful (v3) — `api.doppler.com/v3` |
| **CLI** | Go (goreleaser-built, 385 stars) |
| **Database** | PostgreSQL |
| **Cloud** | Google Cloud Platform (GCP) |
| **CDN** | Cloudflare |
| **Security** | HSTS, reCAPTCHA, SOC 2 Type II |

---

## API Authentication (7 Token Types)

| Token Type | Scope | Format |
|---|---|---|
| **CLI Token** | Read/write all resources | `doppler login` |
| **Personal Token** | Read/write all resources | Dashboard |
| **Service Token** | Per-config access (prefix: `dp.st.`) | Project settings |
| **Service Account Token** | Granular resource access | Service Account |
| **Service Account Identity** | Short-lived OIDC | OIDC flow |
| **SCIM Token** | Users & groups | Dashboard |
| **Audit Token** | Read-only audit | Dashboard |

---

## Rate Limits

| Plan | Reads/min | Secret reads/min | Writes/min |
|---|---|---|---|
| Developer | 240 | 120 | 60 |
| Team | 480 | 240 | 120 |
| Enterprise | 480 | 480 | 240 |

---

## Public Code Repos (DopplerHQ)

| Repository | Language | Stars | Purpose |
|---|---|---|---|
| **[cli](https://github.com/DopplerHQ/cli)** | Go | 385 | Official CLI |
| **[kubernetes-operator](https://github.com/DopplerHQ/kubernetes-operator)** | Go | 55 | K8s operator |
| **[terraform-provider-doppler](https://github.com/DopplerHQ/terraform-provider-doppler)** | Go | 29 | Terraform provider |
| **[cli-action](https://github.com/DopplerHQ/cli-action)** | JS | 64 | GitHub Action |
| **[secrets-fetch-action](https://github.com/DopplerHQ/secrets-fetch-action)** | JS | 27 | Inject secrets into GH Actions |
| **[mcp-server](https://github.com/DopplerHQ/mcp-server)** | TS | 5 | MCP server for AI agents |
| **[node-sdk](https://github.com/DopplerHQ/node-sdk)** | TS | 5 | Node.js SDK |
| **[python-sdk](https://github.com/DopplerHQ/python-sdk)** | Python | 7 | Python SDK |

---

## Recommended Test Vectors

### High Priority
1. **IDOR on config/secrets endpoints** — `/v3/configs/config/secrets` parameter tampering
2. **Auth token leakage** — Service tokens (`dp.st.*`) in error messages/logs
3. **CLI source code analysis** — `github.com/DopplerHQ/cli` — hardcoded keys, credential handling

### Medium Priority
4. **`/auth/me` endpoint** — Token introspection flaws
5. **Share functionality** — `share.doppler.com` — E2E encryption flaws
6. **Change request system** — Privilege escalation via approval bypass
7. **Webhook HMAC validation** — Forged webhooks if secret is weak
8. **Dynamic Secrets lease** — Duration manipulation or revocation bypass

### Low Priority
9. **Trusted IPs bypass** — `X-Forwarded-For` circumvention
10. **OIDC service account** — JWT validation flaws

---

## Historical Reports

| Report ID | Type | Severity | Bounty |
|---|---|---|---|
| H1-2801036 | Availability impact from project name exploit | Low (6.8) | $250 |
| H1-2399386 | GitHub app takeover | Low (3.1) | Hidden |

---

*Report generated: 2026-07-28 by agent3*
