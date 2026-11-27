# MCP usage (same Worker, stateless)

`POST /mcp` speaks JSON-RPC 2.0 with the Streamable-HTTP subset:
`initialize`, `tools/list`, `tools/call`, `ping` (plus `notifications/*`,
which are tolerated). `tools/list`, `tools/call`, and `ping` authenticate
per-request via `x-agent-token` — `initialize` and `notifications/*` do not
(they expose nothing privileged); there are no sessions, so any isolate can
serve any call. No new
dependencies, no Durable Objects, no extra hosting: handlers delegate to the
same `Store` methods as the REST routes.

Tool schemas are versioned in `packages/contracts/mcp-tools.json` (32 tools:
CRUD for recipes, lists, pantry, plans, menus + clip, scale, share, export,
plan feed, sync pull/push, photo signing). `tools/list` serves that file
verbatim.

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

# list tools (names + inputSchema, exactly mcp-tools.json)
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
string, or raw text for `export_recipe` md/html). Tool-level failures
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
