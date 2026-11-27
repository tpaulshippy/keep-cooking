# Agent access with only the device encryption key (#26)

An agent holding **only the syncCode** (the device encryption key from
Settings → End-to-end encryption, no password, no login, no Apple ID) can do
everything the app can: recipes, lists, pantry, plans, menus, photos,
clip/ingest, share, export, sync pull/push.

Two interfaces, one Worker, no new infra:

| Interface | Endpoint | Best for |
|---|---|---|
| Plain REST | `x-agent-token` header on the existing routes + `/agent/*` | curl, scripts, any HTTP client |
| MCP | `POST /mcp` (stateless JSON-RPC 2.0) | tool-calling agents (Claude, Codex) |

Tool schemas are versioned in `packages/contracts/mcp-tools.json` and served
verbatim by `tools/list`. REST shapes are `packages/contracts/openapi.yaml`.

## Auth flow

```
agent machine                          server (blind where it is blind)
─────────────                          ─────────────────────────────────
syncCode (secret, never sent)   HKDF
  ├─ data key ──► AES-GCM encrypt/decrypt of /v2 envelopes (local only)
  └─ agent token ──► x-agent-token header ──► SHA256(token) == stored verifier?
                                                        │
POST /agent/enroll {householdHash, householdId, verifier}  (open: hash knowledge = capability)
  └─► server stores ONLY {householdHash, householdId label, verifier hash}
```

Key derivation (locked — changing any string orphans buckets):

| Value | KDF | Sent to server |
|---|---|---|
| `kid` | `base64url(SHA256(syncCode))[:12]` | routing header only |
| `householdHash` | `hex(SHA256("smidgen-hh-v1" \|\| syncCode \|\| householdId))` | bucket address + enroll binding |
| data key | `HKDF-SHA256(syncCode, salt "smidgen-sync-v1", info "smidgen-sync-v1/hh:<hid>/kid:<kid>")` | **never** (client-side AES-GCM only) |
| agent token | `HKDF-SHA256(syncCode, salt "smidgen-agent-v1", info "smidgen-agent-v1/hh:<hid>/kid:<kid>")`, base64url(32 B) | bearer in `x-agent-token` (TLS) |
| verifier | `hex(SHA256(raw token bytes))` | stored server-side (one-way) |

`householdId` is an explicit **non-secret label** (from the invite bundle,
e.g. `hh-demo`). Secrecy comes from the syncCode, not the label. REST writes
require the label explicitly (`403` otherwise); MCP mutations default an
omitted `householdId` to the enrolled household (`403` on mismatch).

## What the server ever sees (plaintext)

| Route class | Plaintext visible | Blind? |
|---|---|---|
| `PUT/GET /v2/sync/:hash` (+ MCP `sync_push`/`sync_pull`) | routing header only (`v/alg/kid/hash/id/entity/updatedAt/deviceId/deleted/nonce`) | **yes** — ciphertext is opaque; server holds no key |
| `POST /agent/enroll`, `GET /agent/status` | householdHash, householdId label, verifier hash | capability binding, no key material |
| v1 REST (`/recipes`, `/lists`, `/pantry`, `/plans`, `/menus`, `/share/*`, `/export/*`, `/sync/*`, `/photos/sign`) + same-named MCP tools | entity fields in full (legacy plaintext design) | **no** — documented out-of-scope for zero-knowledge (see `docs/e2e-v1.md`); use the blind pipe for private content |
| `POST /clip` (+ MCP `clip`) | submitted URL/caption | **no** — fetch-and-parse inherently sees input |
| Access log | method + redacted path + status + ms | hashes prefix-redacted to 8 chars; bodies/headers never logged |

Scope rules for `x-agent-token` requests: reads are filtered to the enrolled
household (out-of-scope single reads return `404`, never confirming
existence); writes require an explicit matching `householdId` (`403`
otherwise); unknown/malformed tokens are `401` (fail closed, except
`GET /health` which stays open for liveness probes). Rotation: re-enroll the
same hash with a new verifier — the old token stops working immediately.
Losing the syncCode locks the agent out exactly like a lost device (there is
no reset path; keep the recovery kit).

Client crypto lives in [`lib.mjs`](./lib.mjs) (dependency-free WebCrypto —
paste it anywhere). Worked session: [`demo.mjs`](./demo.mjs). Curl: [`rest.md`](./rest.md). MCP: [`mcp.md`](./mcp.md).
