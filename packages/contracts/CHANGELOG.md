# Changelog
## Unreleased — key-only agent access (#26)
- openapi.yaml/json: POST /agent/enroll, GET /agent/status, POST /mcp + AgentToken security scheme
- mcp-tools.json: 32 versioned MCP tools (same Worker, stateless JSON-RPC)
- schema.sql + drizzle 0003: agent_enrollments (hash PK, household label, token verifier hash)
## 0.1.0 (2026-11-22) — initial contracts freeze
- openapi.yaml/json: clip, recipes+scale, lists, pantry, plans, menus, feed.ics, share, export, sync, health
- schema.sql D1 + SyncEnvelope (tombstones, LWW) + ClipReport (jsonld→reader→caption→ocr)
- Photo variants thumb/1024/original, signed URLs <15min
- Seed 12 + 3 near-dupes
