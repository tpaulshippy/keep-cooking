# MCP usage (same Worker, stateless)

`POST /mcp` speaks JSON-RPC 2.0 with the Streamable-HTTP subset:
`initialize` (legacy handshake, kept for 2025 clients), `server/discover`
(modern handshake — returns the supported versions, capabilities, and cache
hints below), `tools/list`, `tools/call`, `ping` (plus `notifications/*`,
which are tolerated: bare notifications get `202` with no body, while a
notification carrying an `id` is acknowledged with `200` and an empty
`result` so the client doesn't hang). `tools/list`, `tools/call`, and
`ping` authenticate per-request via `x-agent-token`; `initialize`,
`server/discover`, and `notifications/*` accept requests without a token
(they expose nothing privileged) — but a present-but-unknown token is
rejected with a plain `401 {"error": "..."}` body for every method by the
header middleware before dispatch (not a JSON-RPC `-32001`), so omit the
header instead of guessing. There are no
sessions, so any isolate can serve any call. No new
dependencies, no Durable Objects, no extra hosting: handlers delegate to the
same `Store` methods as the REST routes.

Tool schemas are versioned in `packages/contracts/mcp-tools.json` (32 tools:
CRUD for recipes, lists, pantry, plans, menus + clip, scale, share, export,
plan feed, sync pull/push, photo signing). `tools/list` serves the `tools`
array of that file (plus static cache hints `ttlMs: 3600000`,
`cacheScope: "private"`).

```bash
BASE=https://<your-worker>
TOKEN=<key-derived token, see rest.md>
M=(-H "x-agent-token: $TOKEN" -H 'content-type: application/json')

# handshake
curl -s -X POST $BASE/mcp "${M[@]}" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}'
# -> {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2026-07-28",
#     "capabilities":{"tools":{"listChanged":false}},
#     "serverInfo":{"name":"keep-cooking-agent","version":"0.1.0"}}}

# modern handshake (MCP 2026-07-28 subset: server/discover only)
curl -s -X POST $BASE/mcp "${M[@]}" \
  -d '{"jsonrpc":"2.0","id":0,"method":"server/discover"}'
# -> {"jsonrpc":"2.0","id":0,"result":{"resultType":"complete",
#     "supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},
#     "_meta":{"io.modelcontextprotocol/serverInfo":{"name":"keep-cooking-agent","version":"0.1.0"}},
#     "instructions":"<one-line tool summary>","ttlMs":3600000,"cacheScope":"private"}}

# list tools (names + inputSchema from the tools array of mcp-tools.json)
curl -s -X POST $BASE/mcp "${M[@]}" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# create a recipe, then plan it, then list groceries — same worked session as REST
curl -s -X POST $BASE/mcp "${M[@]}" -d '{"jsonrpc":"2.0","id":3,"method":"tools/call",
  "params":{"name":"recipe_create","arguments":{"title":"MCP Risotto","servings":2}}}'
# -> {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"{...recipe...}"}]}}
curl -s -X POST $BASE/mcp "${M[@]}" -d '{"jsonrpc":"2.0","id":4,"method":"tools/call",
  "params":{"name":"plan_create","arguments":{"date":"2026-12-03","meal":"dinner","recipeId":"<id>"}}}'
curl -s -X POST $BASE/mcp "${M[@]}" -d '{"jsonrpc":"2.0","id":5,"method":"tools/call",
  "params":{"name":"list_create","arguments":{"name":"MCP groceries","items":[{"name":"arborio rice"}]}}}'
```

Conventions: successful tool results are `result.content[0].text` (a JSON
string — for `export_recipe` md/html the text is a JSON object such as
`{"format":"md","content":"..."}`, so parse the text before reading the
export body). Tool-level failures
(validation, 404, cross-household writes) come back as `result.isError: true`
with the message as text — not as JSON-RPC errors. JSON-RPC errors
(`-32600`, `-32601`, `-32001` auth) are reserved for protocol problems; auth
failures are HTTP 401 with a JSON-RPC-shaped body. `GET /mcp` is `405`.

Blind sync tools (`sync_push`/`sync_pull`) move the same opaque
`EncryptedEnvelope`s as `PUT/GET /v2/sync/:hash` — encrypt with
`encryptEnvelope(dataKey, …)` from [`lib.mjs`](./lib.mjs) before pushing,
`decryptEnvelope` after pulling. Standalone `ingredient`/`step` envelopes are
rejected (fold children into the parent recipe pre-encrypt); per-id delete
travels as `deleted: true`.
