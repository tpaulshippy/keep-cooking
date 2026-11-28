import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeApp, req } from './helpers';

const contractsDir = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'packages', 'contracts');

describe('recipes CRUD + scale + export + misc', () => {
  it('full CRUD lifecycle', async () => {
    const { app } = await makeApp({ seed: false });
    const created = await req(app, 'POST', '/api/recipes', {
      body: {
        title: 'Miso Salmon', servings: 4, householdId: 'hh-demo',
        ingredients: [{ name: 'salmon', quantity: 1.5, unit: 'lb', display: '1 1/2 lb' }],
        steps: [{ text: 'Broil.' }],
      },
    });
    expect(created.status).toBe(201);
    const r = (await created.json()) as { id: string; ingredients: { id: string }[] };
    expect(r.ingredients).toHaveLength(1);

    expect((await req(app, 'GET', `/api/recipes/${r.id}`)).status).toBe(200);
    const upd = await req(app, 'PUT', `/api/recipes/${r.id}`, { body: { title: 'Miso Salmon v2', servings: 4, householdId: 'hh-demo' } });
    expect(upd.status).toBe(200);
    expect(((await upd.json()) as { title: string }).title).toBe('Miso Salmon v2');

    const scale = await req(app, 'POST', `/api/recipes/${r.id}/scale`, { body: { servings: 8 } });
    expect(scale.status).toBe(200);
    const scaled = (await scale.json()) as { servings: number };
    expect(scaled.servings).toBe(8);

    expect((await req(app, 'DELETE', `/api/recipes/${r.id}`)).status).toBe(204);
    expect((await req(app, 'GET', `/api/recipes/${r.id}`)).status).toBe(404);
  });

  it('export json/md/html', async () => {
    const { app } = await makeApp();
    const list = (await (await req(app, 'GET', '/api/recipes?householdId=hh-demo')).json()) as { id: string; title: string }[];
    const id = list[0]!.id;
    expect((await req(app, 'GET', `/api/export/${id}.json`)).status).toBe(200);
    const md = await req(app, 'GET', `/api/export/${id}.md`);
    expect(md.status).toBe(200);
    expect(md.headers.get('content-type')).toContain('text/markdown');
    expect(await md.text()).toContain('#');
    const html = await req(app, 'GET', `/api/export/${id}.html`);
    expect(html.headers.get('content-type')).toContain('text/html');
    const text = await html.text();
    expect(text).toContain('application/ld+json');
    expect(text).toContain(list[0]!.title);
  });

  it('bulk export selects by all/ids with per-format bodies', async () => {
    const { app } = await makeApp({ seed: false });
    const mk = (title: string) => req(app, 'POST', '/api/recipes', {
      body: {
        title, servings: 2, householdId: 'hh-demo',
        ingredients: [{ name: 'flour', display: 'flour' }],
        steps: [{ text: 'Mix.' }],
      },
    });
    const r1 = (await (await mk('Bulk One')).json()) as { id: string };
    const r2 = (await (await mk('Bulk Two')).json()) as { id: string };

    const allJson = await req(app, 'GET', '/api/export?format=json&all=true');
    expect(allJson.status).toBe(200);
    expect(((await allJson.json()) as unknown[])).toHaveLength(2);

    const one = await req(app, 'GET', `/api/export?format=json&ids=${r1.id}`);
    expect(one.status).toBe(200);
    const oneBody = (await one.json()) as { id: string }[];
    expect(oneBody).toHaveLength(1);
    expect(oneBody[0]!.id).toBe(r1.id);

    const md = await req(app, 'GET', `/api/export?format=md&ids=${r1.id},${r2.id}`);
    expect(md.status).toBe(200);
    expect(md.headers.get('content-type')).toContain('text/markdown');
    expect(await md.text()).toContain('---');

    const html = await req(app, 'GET', `/api/export?format=html&ids=${r1.id},${r2.id}`);
    expect(html.status).toBe(200);
    const htmlText = await html.text();
    expect(htmlText).toContain('<hr/>');
    expect(htmlText.match(/<html/g)).toHaveLength(1);

    const zip = await req(app, 'GET', `/api/export?format=paprikarecipes&ids=${r1.id},${r2.id}`);
    expect(zip.status).toBe(200);
    expect(zip.headers.get('content-type')).toContain('application/zip');
    const magic = new Uint8Array(await zip.arrayBuffer()).slice(0, 2);
    expect(Array.from(magic)).toEqual([0x50, 0x4b]);

    const yaml = await req(app, 'GET', `/api/export?format=yaml&ids=${r1.id}`);
    expect(yaml.status).toBe(200);
    expect(yaml.headers.get('content-type')).toContain('text/yaml');

    expect((await req(app, 'GET', '/api/export?format=json')).status).toBe(400);
    expect((await req(app, 'GET', '/api/export?format=csv&all=true')).status).toBe(404);
    expect((await req(app, 'GET', '/api/export?format=json&ids=missing-id')).status).toBe(404);
  });

  it('plans feed.ics is valid calendar', async () => {
    const { app } = await makeApp({ seed: false });
    await req(app, 'POST', '/api/plans', { body: { date: '2026-12-24', meal: 'dinner', note: 'Feast', householdId: 'hh-demo' } });
    const res = await req(app, 'GET', '/api/plans/feed.ics');
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('text/calendar');
    const text = await res.text();
    expect(text).toContain('BEGIN:VCALENDAR');
    expect(text).toContain('DTSTART;VALUE=DATE:20261224');
    expect(text).toContain('END:VCALENDAR');
  });

  it('health + openapi.json byte-equivalent to contracts', async () => {
    const { app } = await makeApp({ seed: false });
    const h = await req(app, 'GET', '/api/health');
    expect(h.status).toBe(200);
    expect(await h.json()).toEqual({ ok: true, version: '0.1.0' });

    const o = await req(app, 'GET', '/api/openapi.json');
    expect(o.status).toBe(200);
    const served = await o.json();
    const file = JSON.parse(readFileSync(join(contractsDir, 'openapi.json'), 'utf8'));
    expect(served).toEqual(file);
  });

  it('lists/pantry/menus CRUD smoke', async () => {
    const { app } = await makeApp({ seed: false });
    const l = await req(app, 'POST', '/api/lists', { body: { name: 'Weekly', items: [{ name: 'Eggs', quantity: '12' }] } });
    expect(l.status).toBe(201);
    const lid = ((await l.json()) as { id: string }).id;
    expect((await req(app, 'GET', `/api/lists/${lid}`)).status).toBe(200);
    expect((await req(app, 'DELETE', `/api/lists/${lid}`)).status).toBe(204);

    const p = await req(app, 'POST', '/api/pantry', { body: { name: 'Flour', quantity: '1kg' } });
    expect(p.status).toBe(201);
    const pid = ((await p.json()) as { id: string }).id;
    expect((await req(app, 'PUT', `/api/pantry/${pid}`, { body: { name: 'Flour', quantity: '2kg' } })).status).toBe(200);

    const m = await req(app, 'POST', '/api/menus', { body: { name: 'Week 1', entries: [{ dayOffset: 0, meal: 'dinner' }] } });
    expect(m.status).toBe(201);
    const mid = ((await m.json()) as { id: string }).id;
    expect((await req(app, 'GET', `/api/menus/${mid}`)).status).toBe(200);
    expect((await req(app, 'DELETE', `/api/menus/${mid}`)).status).toBe(204);
  });
});
