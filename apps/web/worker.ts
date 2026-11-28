// keep-cooking-web: serves apps/web/dist under the keepcooking.app/app
// route prefix. Strips a single leading /app (asset URLs are built with
// vite base '/app/'), serves the file from the [assets] binding, and falls
// back to /index.html for navigations so history deep links cold-load.
// Non-/app paths 404 (this Worker only answers its route).

interface Env {
  ASSETS: Fetcher;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;
    // The asset layer canonicalizes /index.html to / (307), so use / as the
    // SPA entry — it serves dist/index.html with a 200.
    const entry = '/';
    const assetPath = path === '/app' || path === '/app/' ? entry : path.startsWith('/app/') ? path.slice(4) || '/' : null;
    if (assetPath === null) return new Response('not found', { status: 404 });
    const asset = await env.ASSETS.fetch(new Request(new URL(assetPath + url.search, url.origin), request));
    if (asset.status !== 404) return asset;
    const accept = request.headers.get('accept') ?? '';
    if (request.method === 'GET' && accept.includes('text/html')) {
      return env.ASSETS.fetch(new Request(new URL(entry, url.origin), request));
    }
    return new Response('not found', { status: 404 });
  },
};
