# Changelog
## Unreleased — device-auth spec (docs only, no version bump)
- openapi.yaml/json: + POST /v2/devices (open enroll) + POST /v2/devices/{id}/revoke (signed; self-revoke = logout), components.securitySchemes DeviceId/DeviceTs/DeviceSig (apiKey headers), security on mutating ops only (GET/health/openapi/enroll open). Canonical string METHOD\npath+query\nts\nhex(SHA256(body)), 5min replay window (documented limitation).
## 0.1.0 (2026-11-22) — initial contracts freeze
- openapi.yaml/json: clip, recipes+scale, lists, pantry, plans, menus, feed.ics, share, export, sync, health
- schema.sql D1 + SyncEnvelope (tombstones, LWW) + ClipReport (jsonld→reader→caption→ocr)
- Photo variants thumb/1024/original, signed URLs <15min
- Seed 12 + 3 near-dupes
