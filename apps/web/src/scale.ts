// Pure serving scaler: quantity * (target / base). Null-safe.

export function scaleQuantity(
  quantity: number | null | undefined,
  baseServings: number,
  targetServings: number,
): number | null {
  if (quantity == null || !isFinite(quantity)) return null;
  if (!isFinite(baseServings) || baseServings <= 0) return quantity;
  if (!isFinite(targetServings) || targetServings <= 0) return quantity;
  const out = (quantity * targetServings) / baseServings;
  if (!isFinite(out)) return quantity;
  // Round to 2 decimals to avoid float dust (1.5 stays 1.5).
  return Math.round(out * 100) / 100;
}

const FRACS: { value: number; label: string }[] = [
  { value: 0, label: '' },
  { value: 1 / 8, label: '1/8' },
  { value: 1 / 4, label: '1/4' },
  { value: 1 / 3, label: '1/3' },
  { value: 1 / 2, label: '1/2' },
  { value: 2 / 3, label: '2/3' },
  { value: 3 / 4, label: '3/4' },
  { value: 7 / 8, label: '7/8' },
  { value: 1, label: '' }, // carry into whole
];

export function fractionLabel(rem: number): { whole: number; label: string } {
  let best = FRACS[0]!;
  let bestDist = Infinity;
  for (const f of FRACS) {
    const d = Math.abs(f.value - rem);
    if (d < bestDist) {
      bestDist = d;
      best = f;
    }
  }
  if (best.value === 1) return { whole: 1, label: '' };
  return { whole: 0, label: best.label };
}

/** Fraction-rounded display string, e.g. 1.5 -> "1 1/2". Supports
 * 1/8, 1/4, 1/3, 1/2, 2/3, 3/4, 7/8 selection (mirrors api/src/scale.ts). */
export function formatQuantity(q: number | null | undefined, unit = ''): string {
  if (q == null || !isFinite(q)) return unit ? `— ${unit}`.trim() : '—';
  if (q === 0) return unit ? `0 ${unit}`.trim() : '0';
  const sign = q < 0 ? '-' : '';
  const abs = Math.abs(q);
  const rounded8 = Math.round(abs * 8) / 8;
  // Prefer thirds when closer than eighths (e.g. 0.333).
  const rounded3 = Math.round(abs * 3) / 3;
  const use = Math.abs(rounded3 - abs) < Math.abs(rounded8 - abs) - 1e-9 ? rounded3 : rounded8;
  let whole = Math.floor(use + 1e-9);
  let rem = use - whole;
  if (rem > 1 - 1e-9) {
    whole += 1;
    rem = 0;
  } else if (rem < 1e-9) {
    rem = 0;
  }
  const { whole: carry, label } = fractionLabel(rem);
  whole += carry;
  const num = label ? (whole > 0 ? `${whole} ${label}` : label) : `${whole}`;
  const body = `${sign}${num}`;
  return unit ? `${body} ${unit}`.trim() : body;
}
