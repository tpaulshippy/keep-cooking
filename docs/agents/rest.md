# REST examples (key-only agent)

All values below derive from the device encryption key with
[`lib.mjs`](./lib.mjs) (`deriveAll(KEY, HOUSEHOLD)`). `KEY` is never sent;
only `householdHash` (bucket), `token` (bearer), and `verifier` (enrollment)
touch the wire. Test vectors use the published dummy syncCode
`test-only-vector-sync-code-0001` — never a real key.

```bash
export BASE=https://<your-worker>
export HH=hh-agent-demo
export KEY='<paste syncCode from the app recovery kit>'   # required: never sent, only derives locally
# derive with node (prints token/verifier/hash):
node -e "
import('./docs/agents/lib.mjs').then(async ({deriveAll}) => {
  const d = await deriveAll(process.env.KEY, process.env.HH);
  console.log(JSON.stringify({token: d.token, verifier: d.verifier, hash: d.householdHash}, null, 1));
})"
TOKEN=<token from above>   # base64url, 43 chars
```

## Enroll (once per household; re-enroll to rotate)

```bash
# verifier = hex(SHA256(raw token bytes)) — compute it, never send the key
curl -s -X POST $BASE/agent/enroll \
  -H 'content-type: application/json' \
  -d '{"householdHash":"<hash>","householdId":"'"$HH"'","verifier":"<verifier>"}'
# -> 201 {"ok":true,"householdId":"hh-agent-demo","householdHash":"<hash>","hashPrefix8":"<8>"}

curl -s $BASE/agent/status -H "x-agent-token: $TOKEN"
# -> 200 {"householdId":"hh-agent-demo","hashPrefix8":"<8>","deviceId":"agent-<8>"}
```

## Recipes → plan → grocery list (worked session in [`demo.mjs`](./demo.mjs))

```bash
A=(-H "x-agent-token: $TOKEN" -H 'content-type: application/json')

RECIPE=$(curl -s -X POST $BASE/recipes "${A[@]}" -d '{
  "title":"Agent Tomato Soup","servings":4,"householdId":"'"$HH"'",
  "ingredients":[{"name":"tomatoes","quantity":800,"unit":"g","display":"800 g tomatoes"}],
  "steps":[{"text":"Simmer 20 minutes, then blend."}]}')
echo "$RECIPE"   # 201
RID=$(echo "$RECIPE" | node -p "JSON.parse(require('fs').readFileSync(0)).id")

curl -s -X POST $BASE/plans "${A[@]}" \
  -d '{"date":"2026-12-02","meal":"dinner","recipeId":"'"$RID"'","householdId":"'"$HH"'"}'  # 201

curl -s -X POST $BASE/lists "${A[@]}" \
  -d '{"name":"Week groceries","householdId":"'"$HH"'","items":[{"name":"tomatoes","quantity":"800 g tomatoes"}]}'  # 201

curl -s "$BASE/recipes?householdId=$HH" -H "x-agent-token: $TOKEN"  # scoped list
curl -s "$BASE/export/$RID.md" -H "x-agent-token: $TOKEN"           # markdown export
```

## Everything else (same token, same scoping)

```bash
curl -s -X POST $BASE/clip "${A[@]}" -d '{"caption":"Overnight oats\n200 g oats\nStir and chill."}'  # ingest
curl -s "$BASE/photos/sign?key=photos%2F$RID%2Fthumb.jpg" -H "x-agent-token: $TOKEN"                  # signed URL <15min
curl -s -X POST $BASE/share/cookbook "${A[@]}" -d '{"householdId":"'"$HH"'","recipeIds":["'"$RID"'"]}'  # owner-scoped share
curl -s "$BASE/sync/pull?since=1970-01-01T00:00:00.000Z" -H "x-agent-token: $TOKEN"                    # legacy plaintext pull, scoped
```

## Blind sync (private content — the default for recipes)

Encrypt locally with `encryptEnvelope(dataKey, …)` from `lib.mjs`, then move
opaque bytes. The server validates shape + LWW metadata only:

```bash
# $ENV_JSON = one EncryptedEnvelope built by lib.mjs
curl -s -X PUT $BASE/v2/sync/<householdHash> "${A[@]}" -d "[$ENV_JSON]"  # -> {"stored":["<id>"]}
curl -s "$BASE/v2/sync/<householdHash>?since=1970-01-01T00:00:00.000Z" -H "x-agent-token: $TOKEN"
# decrypt each envelope with decryptEnvelope(dataKey, env)
```

## Failure shapes

- `401 {"error":"unknown agent token (enroll with POST /agent/enroll)"}` — unknown/malformed token (fail closed).
- `403 {"error":"agent token is scoped to household '<hh>'…"}` — write naming another household (or none).
- `404 {"error":"not found"}` — out-of-scope single-entity read (no existence oracle).
