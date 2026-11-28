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
  // Round to 2 decimals to avoid float dust (1.5 stays 1.5).
  return Math.round(out * 100) / 100;
}

/** Fraction-rounded display string, e.g. 1.5 -> "1 1/2". Quarters only. */
export function formatQuantity(q: number | null | undefined, unit = ''): string {
  if (q == null || !isFinite(q)) return unit ? `— ${unit}`.trim() : '—';
  const rounded = Math.round(q * 4) / 4;
  const whole = Math.floor(rounded + 1e-9);
  const frac = rounded - whole;
  const fracStr =
    frac < 1e-9 ? '' : frac >= 0.74 ? '3/4' : frac >= 0.49 ? '1/2' : '1/4';
  const num = fracStr ? (whole > 0 ? `${whole} ${fracStr}` : fracStr) : `${whole}`;
  // Non-quarter-exact values keep 2-decimal fallback.
  const body = Math.abs(rounded - q) < 1e-9 ? num : `${Math.round(q * 100) / 100}`;
  return unit ? `${body} ${unit}`.trim() : body;
}
