import { describe, expect, it } from 'vitest';
import { parsePath, href } from './router';

describe('parsePath', () => {
  it('parses base and home', () => {
    expect(parsePath('/app')).toEqual({ name: 'home', params: {} });
    expect(parsePath('/app/')).toEqual({ name: 'home', params: {} });
  });

  it('parses deep links', () => {
    expect(parsePath('/app/recipes')).toEqual({ name: 'recipes', params: {} });
    expect(parsePath('/app/recipes/abc')).toEqual({ name: 'recipeDetail', params: { id: 'abc' } });
    expect(parsePath('/app/recipes/new')).toEqual({ name: 'recipeNew', params: {} });
    expect(parsePath('/app/recipes/abc/edit')).toEqual({ name: 'recipeEdit', params: { id: 'abc' } });
    expect(parsePath('/app/cook/abc')).toEqual({ name: 'cook', params: { id: 'abc' } });
    expect(parsePath('/app/plan').name).toBe('plan');
    expect(parsePath('/app/lists').name).toBe('lists');
    expect(parsePath('/app/menus').name).toBe('menus');
    expect(parsePath('/app/ingest').name).toBe('ingest');
    expect(parsePath('/app/settings').name).toBe('settings');
  });

  it('falls back to home on unknown paths', () => {
    expect(parsePath('/app/nope').name).toBe('home');
  });

  it('routes malformed encodings to home instead of throwing', () => {
    expect(() => parsePath('/app/recipes/%E0%A4%A')).not.toThrow();
    expect(parsePath('/app/recipes/%E0%A4%A').name).toBe('home');
    expect(parsePath('/app/cook/%ZZ').name).toBe('home');
  });
});

describe('href', () => {
  it('builds history paths under /app', () => {
    expect(href('/')).toBe('/app/');
    expect(href('/recipes/abc')).toBe('/app/recipes/abc');
    expect(href('/cook/abc')).toBe('/app/cook/abc');
  });
});
