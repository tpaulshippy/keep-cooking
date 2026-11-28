import { describe, it, expect } from 'vitest';
import { makeApp, req } from './helpers';

// Durability: full-field persistence, child identity, deletions, timers.
describe('update durability (recipes/pantry/lists)', () => {
  it('recipe meta fields persist across update and null clears', async () => {
    const { app } = await makeApp({ seed: false });
    const created = await req(app, 'POST', '/api/recipes', {
      body: {
        title: 'Soup', householdId: 'hh-demo', prepMinutes: 10, cookMinutes: 20,
        rating: 4, source: 'Book', sourceUrl: 'https://example.com/s', categories: ['a', 'b'],
      },
    });
    expect(created.status).toBe(201);
    const r0 = (await created.json()) as { id: string };
    const upd = await req(app, 'PUT', `/api/recipes/${r0.id}`, {
      body: {
        title: 'Soup', householdId: 'hh-demo', prepMinutes: null, cookMinutes: 25,
        rating: null, source: 'Mag', sourceUrl: '', categories: ['c'],
      },
    });
    expect(upd.status).toBe(200);
    const got = (await (await req(app, 'GET', `/api/recipes/${r0.id}`)).json()) as {
      prepMinutes: number | null; cookMinutes: number | null; rating: number | null;
      source: string; sourceUrl: string; categories: string[];
    };
    expect(got.prepMinutes).toBeNull();
    expect(got.cookMinutes).toBe(25);
    expect(got.rating).toBeNull();
    expect(got.source).toBe('Mag');
    expect(got.categories).toEqual(['c']);
  });

  it('removed ingredients/steps stay removed after update; stable ids kept', async () => {
    const { app } = await makeApp({ seed: false });
    const created = await req(app, 'POST', '/api/recipes', {
      body: {
        title: 'R', householdId: 'hh-demo',
        ingredients: [{ id: 'ing-keep', name: 'Salt' }, { id: 'ing-drop', name: 'Pepper' }],
        steps: [
          { id: 'step-keep', text: 'Stir', timers: [{ seconds: 60, label: 'Rest' }] },
          { id: 'step-drop', text: 'Skip' },
        ],
      },
    });
    expect(created.status).toBe(201);
    const r0 = (await created.json()) as {
      id: string;
      ingredients: { id: string }[];
      steps: { id: string; timers: { seconds: number; label: string }[] }[];
    };
    expect(r0.ingredients.map((g) => g.id).sort()).toEqual(['ing-drop', 'ing-keep']);
    // Timers round-trip through create.
    expect(r0.steps.find((s) => s.id === 'step-keep')?.timers).toEqual([{ seconds: 60, label: 'Rest' }]);

    const upd = await req(app, 'PUT', `/api/recipes/${r0.id}`, {
      body: {
        title: 'R', householdId: 'hh-demo',
        ingredients: [{ id: 'ing-keep', name: 'Sea salt' }],
        steps: [{ id: 'step-keep', text: 'Stir well', timers: [{ seconds: 60, label: 'Rest' }] }],
      },
    });
    expect(upd.status).toBe(200);
    const r1 = (await upd.json()) as { ingredients: { id: string; name: string }[]; steps: { id: string }[] };
    expect(r1.ingredients).toHaveLength(1);
    expect(r1.ingredients[0]).toMatchObject({ id: 'ing-keep', name: 'Sea salt' });
    expect(r1.steps.map((s) => s.id)).toEqual(['step-keep']);

    // Reload: the deletion must still hold (memory store replaces children).
    const got = (await (await req(app, 'GET', `/api/recipes/${r0.id}`)).json()) as {
      ingredients: { id: string }[]; steps: { id: string }[];
    };
    expect(got.ingredients.map((g) => g.id)).toEqual(['ing-keep']);
    expect(got.steps.map((s) => s.id)).toEqual(['step-keep']);
  });

  it('step timers validate (seconds >= 1)', async () => {
    const { app } = await makeApp({ seed: false });
    const bad = await req(app, 'POST', '/api/recipes', {
      body: { title: 'R', householdId: 'hh-demo', steps: [{ text: 'X', timers: [{ seconds: 0, label: 'Z' }] }] },
    });
    expect(bad.status).toBe(400);
  });

  it('pantry full fields persist; blank expiresAt is rejected by contract', async () => {
    const { app } = await makeApp({ seed: false });
    const bad = await req(app, 'POST', '/api/pantry', {
      body: { name: 'Milk', householdId: 'hh-demo', expiresAt: '' },
    });
    expect(bad.status).toBe(400);
    const created = await req(app, 'POST', '/api/pantry', {
      body: {
        name: 'Milk', householdId: 'hh-demo', quantity: '1 gal', location: 'Fridge',
        expiresAt: '2026-12-01', lowThreshold: '1', barcode: '123',
      },
    });
    expect(created.status).toBe(201);
    const p0 = (await created.json()) as { id: string };
    const upd = await req(app, 'PUT', `/api/pantry/${p0.id}`, {
      body: {
        name: 'Milk', householdId: 'hh-demo', quantity: '2 gal', location: 'Door',
        expiresAt: null, lowThreshold: '2', barcode: '456',
      },
    });
    expect(upd.status).toBe(200);
    const got = (await upd.json()) as {
      location: string; expiresAt: string | null; lowThreshold: string; barcode: string;
    };
    expect(got.location).toBe('Door');
    expect(got.expiresAt).toBeNull();
    expect(got.lowThreshold).toBe('2');
    expect(got.barcode).toBe('456');
  });

  it('list item delete + repeated edit are durable; ids stable', async () => {
    const { app } = await makeApp({ seed: false });
    const created = await req(app, 'POST', '/api/lists', {
      body: {
        name: 'Shop', householdId: 'hh-demo',
        items: [{ id: 'it-keep', name: 'Eggs' }, { id: 'it-drop', name: 'Bacon' }],
      },
    });
    expect(created.status).toBe(201);
    const l0 = (await created.json()) as { id: string };
    const upd1 = await req(app, 'PUT', `/api/lists/${l0.id}`, {
      body: { name: 'Shop', householdId: 'hh-demo', items: [{ id: 'it-keep', name: 'Eggs', quantity: '12' }] },
    });
    expect(upd1.status).toBe(200);
    const upd2 = await req(app, 'PUT', `/api/lists/${l0.id}`, {
      body: {
        name: 'Shop v2', householdId: 'hh-demo',
        items: [{ id: 'it-keep', name: 'Eggs', quantity: '12', checked: true }],
      },
    });
    const l2 = (await upd2.json()) as { items: { id: string; quantity: string; checked: boolean }[] };
    expect(l2.items).toHaveLength(1);
    expect(l2.items[0]).toMatchObject({ id: 'it-keep', quantity: '12', checked: true });
  });
});
