import { readFileSync, existsSync, mkdirSync, cpSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const pub = join(root, "public");
const dist = join(root, "dist");
const failures = [];
const check = (name, cond) => {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}`);
  if (!cond) failures.push(name);
};

const index = readFileSync(join(pub, "index.html"), "utf8");

// Required sections (issue #29 scope)
for (const s of ["tour", "how", "free", "get", "faq", "contact"]) {
  check(`section #${s} present`, index.includes(`id="${s}"`));
}
check("hero section present", index.includes('class="hero"') && index.includes('id="hero-title"'));
// Feature tour coverage: clip/cook/organize/shop/plan/sync
for (const w of ["Clip anything", "Cook hands-free", "Plan the week", "Shop &amp; pantry", "Organize your way", "Sync &amp; share"]) {
  check(`tour card "${w}"`, index.includes(w));
}
// Copy accuracy vs README: free/MIT, no invented pricing (the single
// allowlisted Paprika migration hook lives in the free section)
check("no invented pricing", !/\$\d+\.\d+|\/mo|per month/i.test(index.replace("Paprika 4 Premium ($14.99/yr)", "")));
check("exactly one Paprika mention", (index.match(/paprika/gi) || []).length === 1);
check("MIT mentioned", index.includes("MIT"));
check("GitHub link", index.includes("https://github.com/tpaulshippy/keep-cooking"));
check("/app CTA link", index.includes('href="/app"'));
check("native apps marked coming soon", index.includes("coming soon"));
check("no store links implying availability", !/testflight|play\.google/i.test(index));
check("privacy stub linked", index.includes("/privacy.html"));
check("JSON-LD SoftwareApplication", index.includes("SoftwareApplication"));
check("OG tags", index.includes("og:image") && index.includes("og-image.png")
  && index.includes("og:image:width") && index.includes("og:image:height"));
// Dark mode: prefers-color-scheme block present, eyebrow tuned in both modes
const css = readFileSync(join(pub, "styles.css"), "utf8");
check("dark mode block present", css.includes("@media (prefers-color-scheme: dark)"));
check("eyebrow color in light mode", /\.eyebrow\s*\{[^}]*color:\s*#8f4d15/.test(css));
const darkBlock = css.slice(css.indexOf("@media (prefers-color-scheme: dark)"));
check("eyebrow color in dark mode", /\.eyebrow\s*\{[^}]*color:\s*#[0-9a-f]{6}/i.test(darkBlock));
check("alt text on all images", !/<img\b(?![^>]*\salt=)/.test(index)
  && !/<img\b(?![^>]*\salt=)/.test(readFileSync(join(pub, "privacy.html"), "utf8")));
check("no heavy client JS (only nav.js)", !/react|vue|next|alpine|jquery/i.test(index));
// Path-collision: no /api or /app files of our own (real isolation is
// separate hosting — API Worker routes + /app project — plus this absence)
check("no api dir in public", !existsSync(join(pub, "api")));
check("no app dir in public", !existsSync(join(pub, "app")));
// Every local <img src> must resolve to a file under public/
for (const m of index.matchAll(/<img\b[^>]*\ssrc="([^"]+)"/g)) {
  const src = m[1];
  if (src.startsWith("/")) {
    check(`img resolves: ${src}`, existsSync(join(pub, src.slice(1))));
  }
}
for (const f of ["index.html", "privacy.html", "styles.css", "nav.js", "favicon.svg", "og-image.svg", "og-image.png", "robots.txt", "sitemap.xml",
  "img/recipes.jpg", "img/clip.jpg", "img/plan.jpg", "img/shop.jpg"]) {
  check(`asset ${f} exists`, existsSync(join(pub, f)));
}

// Build: clear dist/ first (no stale files), then copy public/ -> dist/
rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });
cpSync(pub, dist, { recursive: true });
// NOTE: Pages _routes.json only controls Functions invocation — it cannot
// reserve /api/* or /app/* served by other services. Kept as a harmless
// hint; real isolation is separate Worker routes + no /api /app files above.
writeFileSync(join(dist, "_routes.json"), JSON.stringify({
  version: 1,
  include: ["/*"],
  exclude: ["/api/*", "/app/*"],
}, null, 2) + "\n");
console.log("dist/ rebuilt from public/ (stale files cleared)");

if (failures.length) {
  console.error(`\n${failures.length} check(s) failed`);
  process.exit(1);
}
console.log("\nAll marketing checks green.");
