# Changelog
## Unreleased — key-only agent access (#26, on top of 0.2.0 device-auth)
- openapi.yaml/json: POST /agent/enroll, GET /agent/status, POST /mcp + AgentToken security scheme (agent token is an alternative credential to the device signature for mutations)
- mcp-tools.json: 32 versioned MCP tools (same Worker, stateless JSON-RPC)
- schema.sql + drizzle 0004: agent_enrollments (hash PK, household label, token verifier hash)
## 0.2.0 — device-auth contract (BREAKING)
- Every mutating endpoint now requires signed `x-device-*` headers (Ed25519 over `METHOD\npath+query\nts\nhex(SHA256(body))`, 5min replay window, documented limitation). Existing 0.1.0 clients get 401 on writes until they enroll + sign.
- openapi.yaml/json: + POST /v2/devices (open enroll; 201 first enroll, 200 same-key re-enroll, 410 revoked id re-enrolled, 409 id taken by another key) + POST /v2/devices/{id}/revoke (signed; self-revoke = logout), components.securitySchemes DeviceId/DeviceTs/DeviceSig (apiKey headers), security on mutating ops only (GET/health/openapi/enroll open).
- First-claim bootstrap: on an empty household the first verified writer becomes owner; further devices stay viewer until granted (no membership seed).
## 0.1.0 (2026-11-22) — initial contracts freeze
- openapi.yaml/json: clip, recipes+scale, lists, pantry, plans, menus, feed.ics, share, export, sync, health
- schema.sql D1 + SyncEnvelope (tombstones, LWW) + ClipReport (jsonld→reader→caption→ocr)
- Photo variants thumb/1024/original, signed URLs <15min
- Seed 12 + 3 near-dupes
