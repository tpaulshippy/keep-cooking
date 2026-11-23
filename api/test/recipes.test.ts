import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeApp, req } from './helpers';

const contractsDir = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'packages', 'contracts');

describe('recipes CRUD + scale + export + misc', () => {
  it('full CRUD lifecycle', async () => {
    const { app } = await makeApp({ seed: false });
    const created = await req(app, 'POST', '/recipes', {
      body: {
        title: 'Miso Salmon', servings: 4, householdId: 'hh-demo',
        ingredients: [{ name: 'salmon', quantity: 1.5, unit: 'lb', display: '1 1/2 lb' }],
        steps: [{ text: 'Broil.' }],
      },
    });
    expect(created.status).toBe(201);
    const r = (await created.json()) as { id: string; ingredients: { id: string }[] };
    expect(r.ingredients).toHaveLength(1);

    expect((await req(app, 'GET', `/recipes/${r.id}`)).status).toBe(200);
    const upd = await req(app, 'PUT', `/recipes/${r.id}`, { body: { title: 'Miso Salmon v2', servings: 4, householdId: 'hh-demo' } });
    expect(upd.status).toBe(200);
    expect(((await upd.json()) as { title: string }).title).toBe('Miso Salmon v2');

    const scale = await req(app, 'POST', `/recipes/${r.id}/scale`, { body: { servings: 8 } });
    expect(scale.status).toBe(200);
    const scaled = (await scale.json()) as { servings: number };
    expect(scaled.servings).toBe(8);

    expect((await req(app, 'DELETE', `/recipes/${r.id}`)).status).toBe(204);
    expect((await req(app, 'GET', `/recipes/${r.id}`)).status).toBe(404);
  });

  it('export json/md/html', async () => {
    const { app } = await makeApp();
    const list = (await (await req(app, 'GET', '/recipes?householdId=hh-demo')).json()) as { id: string; title: string }[];
    const id = list[0]!.id;
    expect((await req(app, 'GET', `/export/${id}.json`)).status).toBe(200);
    const md = await req(app, 'GET', `/export/${id}.md`);
    expect(md.status).toBe(200);
    expect(md.headers.get('content-type')).toContain('text/markdown');
    expect(await md.text()).toContain('#');
    const html = await req(app, 'GET', `/export/${id}.html`);
    expect(html.headers.get('content-type')).toContain('text/html');
    const text = await html.text();
    expect(text).toContain('application/ld+json');
    expect(text).toContain(list[0]!.title);
  });

  it('plans feed.ics is valid calendar', async () => {
    const { app } = await makeApp({ seed: false });
    await req(app, 'POST', '/plans', { body: { date: '2026-12-24', meal: 'dinner', note: 'Feast', householdId: 'hh-demo' } });
    const res = await req(app, 'GET', '/plans/feed.ics');
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('text/calendar');
    const text = await res.text();
    expect(text).toContain('BEGIN:VCALENDAR');
    expect(text).toContain('DTSTART;VALUE=DATE:20261224');
    expect(text).toContain('END:VCALENDAR');
  });

  it('health + openapi.json byte-equivalent to contracts', async () => {
    const { app } = await makeApp({ seed: false });
    const h = await req(app, 'GET', '/health');
    expect(h.status).toBe(200);
    expect(await h.json()).toEqual({ ok: true, version: '0.1.0' });

    const o = await req(app, 'GET', '/openapi.json');
    expect(o.status).toBe(200);
    const served = await o.json();
    const file = JSON.parse(readFileSync(join(contractsDir, 'openapi.json'), 'utf8'));
    expect(served).toEqual(file);
  });

  it('lists/pantry/menus CRUD smoke', async () => {
    const { app } = await makeApp({ seed: false });
    const l = await req(app, 'POST', '/lists', { body: { name: 'Weekly', items: [{ name: 'Eggs', quantity: '12' }] } });
    expect(l.status).toBe(201);
    const lid = ((await l.json()) as { id: string }).id;
    expect((await req(app, 'GET', `/lists/${lid}`)).status).toBe(200);
    expect((await req(app, 'DELETE', `/lists/${lid}`)).status).toBe(204);

    const p = await req(app, 'POST', '/pantry', { body: { name: 'Flour', quantity: '1kg' } });
    expect(p.status).toBe(201);
    const pid = ((await p.json()) as { id: string }).id;
    expect((await req(app, 'PUT', `/pantry/${pid}`, { body: { name: 'Flour', quantity: '2kg' } })).status).toBe(200);

    const m = await req(app, 'POST', '/menus', { body: { name: 'Week 1', entries: [{ dayOffset: 0, meal: 'dinner' }] } });
    expect(m.status).toBe(201);
    const mid = ((await m.json()) as { id: string }).id;
    expect((await req(app, 'GET', `/menus/${mid}`)).status).toBe(200);
    expect((await req(app, 'DELETE', `/menus/${mid}`)).status).toBe(204);
  });
});
