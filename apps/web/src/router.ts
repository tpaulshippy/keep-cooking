// History router with /app base. Deep-linkable cold loads (/app/recipes/:id)
// resolve to the same index.html — the Worker assets handler falls back
// unknown /app/* paths to /app/index.html (documented in README) — and the
// pathname after the base resolves the view client-side.

export const BASE = '/app';

export type RouteName =
  | 'home' | 'recipes' | 'recipeDetail' | 'cook' | 'plan'
  | 'lists' | 'menus' | 'ingest' | 'settings';

export interface Route { name: RouteName; params: Record<string, string>; }

function stripBase(pathname: string): string {
  if (pathname === BASE) return '/';
  if (pathname.startsWith(BASE + '/')) return pathname.slice(BASE.length) || '/';
  return pathname; // dev at root or unknown: treat whole pathname as route
}

function safeDecode(s: string): string | null {
  try {
    return decodeURIComponent(s);
  } catch {
    return null; // malformed % encodings must not kill first render
  }
}

export function parsePath(pathname: string): Route {
  const path = stripBase(pathname);
  const seg = path.split('/').filter(Boolean);
  if (seg.length === 0) return { name: 'home', params: {} };
  const [a, b, c] = seg;
  if (a === 'recipes' && b && c === undefined) {
    const id = safeDecode(b);
    return id === null ? { name: 'home', params: {} } : { name: 'recipeDetail', params: { id } };
  }
  if (a === 'recipes') return { name: 'recipes', params: {} };
  if (a === 'cook' && b) {
    const id = safeDecode(b);
    return id === null ? { name: 'home', params: {} } : { name: 'cook', params: { id } };
  }
  if (a === 'plan') return { name: 'plan', params: {} };
  if (a === 'lists') return { name: 'lists', params: {} };
  if (a === 'menus') return { name: 'menus', params: {} };
  if (a === 'ingest') return { name: 'ingest', params: {} };
  if (a === 'settings') return { name: 'settings', params: {} };
  return { name: 'home', params: {} };
}

/** History path for an in-app route, e.g. href('/recipes/abc') -> '/app/recipes/abc'. */
export function href(path: string): string {
  const p = path.startsWith('/') ? path : `/${path}`;
  return p === '/' ? `${BASE}/` : `${BASE}${p}`;
}

export function navigate(path: string): void {
  history.pushState(null, '', href(path));
  window.dispatchEvent(new PopStateEvent('popstate'));
}

/** One-time upgrade: legacy hash URLs (#/recipes/...) become history URLs. */
export function upgradeHashOnce(): void {
  if (location.hash.startsWith('#/')) {
    history.replaceState(null, '', href(location.hash.slice(1) || '/'));
  }
}

/**
 * Wire popstate + internal-link interception. Returns an unlisten function.
 * Only same-origin /app/* left-clicks without modifiers are intercepted;
 * everything else (external, new-tab, downloads) passes through.
 */
export function initRouter(onRoute: () => void): () => void {
  upgradeHashOnce();
  const onPop = () => onRoute();
  const onClick = (e: MouseEvent) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const anchor = (e.target as HTMLElement).closest?.('a[href]') as HTMLAnchorElement | null;
    if (!anchor) return;
    const hrefAttr = anchor.getAttribute('href');
    if (!hrefAttr || anchor.hasAttribute('download') || anchor.target === '_blank') return;
    let url: URL;
    try {
      url = new URL(hrefAttr, location.origin);
    } catch {
      return;
    }
    if (url.origin !== location.origin) return;
    if (url.pathname !== BASE && !url.pathname.startsWith(BASE + '/')) return;
    e.preventDefault();
    if (url.pathname + url.search + url.hash !== location.pathname + location.search + location.hash) {
      history.pushState(null, '', url.pathname + url.search + url.hash);
    }
    onRoute();
  };
  window.addEventListener('popstate', onPop);
  document.addEventListener('click', onClick);
  return () => {
    window.removeEventListener('popstate', onPop);
    document.removeEventListener('click', onClick);
  };
}
