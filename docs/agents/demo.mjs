// Worked session (#26 acceptance demo): an agent holding ONLY the device
// encryption key creates a recipe → adds it to a plan → generates a grocery
// list, then proves the blind sync path with a real encrypted envelope.
//
// Usage (from a clean machine, nothing to install — Node 18+ only):
//   export KEEPCOOKING_KEY='<paste syncCode from the app recovery kit>'
//   export KEEPCOOKING_HOUSEHOLD='<householdId from the invite bundle>'
//   BASE=https://<your-worker> node docs/agents/demo.mjs
//
// Local check: BASE=http://127.0.0.1:8787 node docs/agents/demo.mjs
// (with `wrangler dev` running in api/). Uses a scratch household label so
// it never touches real data. Exits non-zero on any unexpected status.
import { deriveAll, encryptEnvelope, decryptEnvelope, enroll, agentFetch } from './lib.mjs';

const BASE = (process.env.BASE || 'http://127.0.0.1:8787').replace(/\/$/, '');
const KEY = process.env.KEEPCOOKING_KEY;
const HOUSEHOLD = process.env.KEEPCOOKING_HOUSEHOLD || 'hh-agent-demo';
if (!KEY) {
  console.error('KEEPCOOKING_KEY is required (the device encryption key / syncCode).');
  process.exit(2);
}

function check(step, res, want) {
  const ok = Array.isArray(want) ? want.includes(res.status) : res.status === want;
  console.log(`${ok ? 'ok' : 'FAIL'} ${step} -> ${res.status}`);
  if (!ok) {
    console.log(JSON.stringify(res.json ?? res.text)?.slice(0, 500));
    process.exit(1);
  }
  return res.json;
}

const d = await deriveAll(KEY, HOUSEHOLD);
console.log(`derived kid=${d.kid} hashPrefix8=${d.hashPrefix8} (syncCode never leaves this machine)`);
console.log(`target ${BASE} household "${HOUSEHOLD}" — demo records will be created there; keep the default scratch label, never a real household.`);

// 1. enroll the token verifier (server stores a hash of the token, not the key)
const e = await enroll(BASE, { householdHash: d.householdHash, householdId: HOUSEHOLD, verifier: d.verifier });
console.log(`ok enroll -> household ${e.householdId} prefix ${e.hashPrefix8}`);
const api = agentFetch(BASE, d.token);
check('status', await api('GET', '/agent/status'), 200);

// 2. create a recipe with ONLY the key-derived token
const recipe = check(
  'create recipe',
  await api('POST', '/recipes', {
    title: 'Agent Demo Tomato Soup',
    servings: 4,
    householdId: HOUSEHOLD,
    ingredients: [
      { name: 'tomatoes', quantity: 800, unit: 'g', display: '800 g tomatoes' },
      { name: 'onion', quantity: 1, unit: '', display: '1 onion' },
    ],
    steps: [{ text: 'Simmer everything 20 minutes, then blend.' }],
  }),
  201,
);

// 3. add it to the plan
const plan = check(
  'create plan',
  await api('POST', '/plans', { date: '2026-12-02', meal: 'dinner', recipeId: recipe.id, householdId: HOUSEHOLD }),
  201,
);

// 4. generate a grocery list from the recipe ingredients
const list = check(
  'create grocery list',
  await api('POST', '/lists', {
    name: 'Demo week groceries',
    householdId: HOUSEHOLD,
    items: recipe.ingredients.map((g) => ({ name: g.name, quantity: g.display || String(g.quantity ?? '') })),
  }),
  201,
);

// 5. blind sync round-trip: encrypt locally, push bytes, pull bytes, decrypt
const env = await encryptEnvelope(d.dataKey, {
  kid: d.kid,
  householdHash: d.householdHash,
  id: recipe.id,
  entity: 'recipe',
  updatedAt: new Date().toISOString(),
  deviceId: `agent-${d.hashPrefix8}`,
  payload: { ...recipe, householdId: HOUSEHOLD },
});
check('blind sync_push', await api('PUT', `/v2/sync/${d.householdHash}`, [env]), 200);
const pulled = check('blind sync_pull', await api('GET', `/v2/sync/${d.householdHash}?since=1970-01-01T00:00:00.000Z`), 200);
const back = await decryptEnvelope(d.dataKey, pulled.find((x) => x.id === recipe.id));
console.log(`ok blind decrypt -> title "${back.payload.title}" (the /v2 sync payload traveled as ciphertext only)`);

console.log('\nworked session complete:');
console.log(`  recipe ${recipe.id} "${recipe.title}"`);
console.log(`  plan   ${plan.id} ${plan.date} ${plan.meal}`);
console.log(`  list   ${list.id} "${list.name}" (${list.items.length} items)`);
