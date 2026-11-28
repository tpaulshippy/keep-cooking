import { z } from 'zod';

// ---- Shared ----
export const roleSchema = z.enum(['owner', 'member', 'viewer']);
export const entitySchema = z.enum(['recipe', 'ingredient', 'step', 'list', 'pantryItem', 'plan', 'menu']);

export const syncEnvelopeSchema = z.object({
  id: z.string().uuid(),
  updatedAt: z.string().datetime(),
  deviceId: z.string().min(1),
  deleted: z.boolean().optional().default(false),
  entity: z.string(), // validated per-route against entitySchema where strict
  payload: z.record(z.unknown()).optional().default({}),
});
export type SyncEnvelope = z.infer<typeof syncEnvelopeSchema>;

// ---- Clip ----
export const clipRequestSchema = z
  .object({
    url: z.string().url().optional(),
    caption: z.string().max(20000).optional(),
    source: z.enum(['url', 'tiktok', 'instagram', 'youtube', 'ocr', 'clipboard']).optional(),
  })
  .refine((v) => v.url || v.caption, { message: 'url or caption is required' });

// ---- Recipes ----
export const ingredientInputSchema = z.object({
  id: z.string().max(120).optional(),
  name: z.string().min(1).max(300),
  quantity: z.number().nullable().optional(),
  unit: z.string().max(60).optional().default(''),
  display: z.string().max(120).optional().default(''),
  position: z.number().int().min(0).optional().default(0),
});
export const stepTimerInputSchema = z.object({
  seconds: z.number().int().min(1),
  label: z.string().max(120).optional().default('Timer'),
});
export const stepInputSchema = z.object({
  id: z.string().max(120).optional(),
  position: z.number().int().min(0).optional().default(0),
  text: z.string().min(1).max(8000),
  timers: z.array(stepTimerInputSchema).max(20).optional().default([]),
});
export const photoKeysSchema = z
  .object({
    original: z.string().optional().default(''),
    large1024: z.string().optional().default(''),
    thumb: z.string().optional().default(''),
  })
  .optional()
  .default({});

export const recipeInputSchema = z.object({
  title: z.string().min(1).max(300),
  description: z.string().max(8000).optional().default(''),
  servings: z.number().min(0.25).max(100).optional().default(4),
  prepMinutes: z.number().int().min(0).max(10080).nullable().optional(),
  cookMinutes: z.number().int().min(0).max(10080).nullable().optional(),
  rating: z.number().min(0).max(5).nullable().optional(),
  isFavorite: z.boolean().optional().default(false),
  source: z.string().max(300).optional().default(''),
  sourceUrl: z.string().max(2000).optional().default(''),
  categories: z.array(z.string().max(60)).max(30).optional().default([]),
  photoKeys: photoKeysSchema,
  ingredients: z.array(ingredientInputSchema).max(200).optional().default([]),
  steps: z.array(stepInputSchema).max(200).optional().default([]),
  householdId: z.string().max(120).optional().default('hh-demo'),
});

// ---- Lists ----
export const listItemInputSchema = z.object({
  id: z.string().max(120).optional(),
  name: z.string().min(1).max(300),
  quantity: z.string().max(120).optional().default(''),
  aisle: z.string().max(120).optional().default(''),
  checked: z.boolean().optional().default(false),
  recipeId: z.string().max(120).nullable().optional(),
});
export const shoppingListInputSchema = z.object({
  name: z.string().min(1).max(200),
  householdId: z.string().max(120).optional().default('hh-demo'),
  items: z.array(listItemInputSchema).max(1000).optional().default([]),
});

// ---- Pantry ----
export const pantryInputSchema = z.object({
  name: z.string().min(1).max(300),
  quantity: z.string().max(120).optional().default(''),
  location: z.string().max(120).optional().default(''),
  expiresAt: z.string().date().nullable().optional(),
  lowThreshold: z.string().max(120).optional().default(''),
  barcode: z.string().max(120).optional().default(''),
  householdId: z.string().max(120).optional().default('hh-demo'),
});

// ---- Plans / menus ----
export const planInputSchema = z.object({
  date: z.string().date(),
  meal: z.enum(['breakfast', 'lunch', 'dinner', 'snack']),
  recipeId: z.string().max(120).nullable().optional(),
  note: z.string().max(2000).optional().default(''),
  servings: z.number().min(0.25).max(100).nullable().optional(),
  householdId: z.string().max(120).optional().default('hh-demo'),
});
export const menuEntrySchema = z.object({
  dayOffset: z.number().int().min(0).max(365).optional().default(0),
  meal: z.string().max(40).optional().default('dinner'),
  recipeId: z.string().max(120).optional().default(''),
  servings: z.number().min(0.25).max(100).nullable().optional(),
});
export const menuInputSchema = z.object({
  name: z.string().min(1).max(200),
  householdId: z.string().max(120).optional().default('hh-demo'),
  entries: z.array(menuEntrySchema).max(365).optional().default([]),
});

// ---- Scale / share ----
export const scaleRequestSchema = z.object({
  servings: z.number().min(0.25).max(100),
});
export const shareRequestSchema = z.object({
  householdId: z.string().min(1).max(120),
  recipeIds: z.array(z.string().min(1)).min(1).max(500),
  expiresInDays: z.number().int().min(1).max(365).optional().default(30),
});

export function parseOrThrow<T>(schema: z.ZodType<T>, data: unknown): T {
  const r = schema.safeParse(data);
  if (!r.success) {
    const err = new Error('validation failed') as Error & { status?: number; details?: unknown };
    err.status = 400;
    err.details = r.error.flatten();
    throw err;
  }
  return r.data;
}
