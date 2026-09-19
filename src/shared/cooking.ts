// Cuts, target temperatures and named methods — the cooking knowledge base.
//
// The data lives in `data/cooking.json` at the repo root and is loaded, not
// hardcoded. Both apps read that one file (ADR 0007): iOS vendors a copy into
// its bundle, the desktop copies it into `dist/data/`. A corrected safety
// figure is therefore fixed once rather than once per app, and
// `npm run cooking:check` fails the build if the two copies drift.
//
// Safe minimums are USDA FSIS figures. Doneness temperatures for whole-muscle
// beef and lamb are the conventional culinary ones and **some sit below the
// USDA minimum** — they are labelled as preferences and the safe minimum is
// always shown alongside, never quietly omitted, so the choice is the cook's
// and is an informed one.
//
// Texture temperatures are ordinary barbecue practice: collagen renders in the
// 195–205° band, which is why a brisket is "done" far above any safety
// threshold. Those are guides — probe tenderness is the real test.

// Why a target temperature is what it is.
//
// Keeping these apart is the point of the whole catalogue. "165° for chicken"
// and "203° for brisket" are not the same kind of number: one is a food-safety
// floor you must not go under, the other is where collagen has rendered and is
// purely about texture. Presenting them identically is how someone talks
// themselves out of the first one.
export type TargetKind = 'safeMinimum' | 'doneness' | 'texture';

export type MeatCategory =
  | 'beef' | 'pork' | 'poultry' | 'lamb' | 'seafood' | 'ground' | 'other';

export const CATEGORY_LABELS: Record<MeatCategory, string> = {
  beef: 'Beef',
  pork: 'Pork',
  poultry: 'Poultry',
  lamb: 'Lamb & Veal',
  seafood: 'Fish & Seafood',
  ground: 'Ground & Sausage',
  other: 'Other',
};

export const CATEGORY_ORDER: MeatCategory[] =
  ['beef', 'pork', 'poultry', 'lamb', 'seafood', 'ground', 'other'];

export interface MeatTarget {
  label: string;
  temperature: number;
  kind: TargetKind;
}

// One stage of a multi-step method.
export interface MethodStep {
  title: string;
  detail: string;
  minutes?: number;    // roughly how long, where the method specifies it
  grillTemp?: number;  // when this stage differs from the method's temperature
}

// A named technique — the "how", where the target temperature alone doesn't
// capture it. 3-2-1 ribs and 0-400 wings aren't different temperatures, they're
// different *procedures*, and the procedure is what people actually look up.
// A target of 203° tells you nothing about when to wrap.
export interface CookMethod {
  name: string;
  summary: string;
  steps: MethodStep[];
  grillTemp?: number;
  note?: string;
}

export interface MeatCut {
  name: string;
  category: MeatCategory;
  targets: MeatTarget[];       // ascending
  note?: string;
  grillTemp?: number;
  methods: CookMethod[];
  // Overrides the category floor where the product genuinely has a different
  // one. A fully-cooked ham being *reheated* is safe at 140°, while raw pork is
  // 145° — the floor is a property of the product, not just the animal.
  safeFloorOverride?: number;
}

export interface CookingData {
  version: number;
  cuts: MeatCut[];
  methods: CookMethod[];
  safeMinimums: Partial<Record<MeatCategory, number>>;
  note?: string;
}

// ---------------------------------------------------------------------------

export function cutId(cut: MeatCut): string {
  return `${cut.category}-${cut.name}`;
}

export function targetId(target: MeatTarget): string {
  return `${target.label}-${target.temperature}`;
}

// Total time where every stage declares one.
export function methodTotalMinutes(method: CookMethod): number | null {
  const known = method.steps.map((s) => s.minutes).filter((m): m is number => typeof m === 'number');
  return known.length === method.steps.length && known.length > 0
    ? known.reduce((a, b) => a + b, 0)
    : null;
}

export function methodDurationLabel(method: CookMethod): string | null {
  const total = methodTotalMinutes(method);
  if (total === null) return null;
  const h = Math.floor(total / 60), m = total % 60;
  if (h === 0) return `${m}m`;
  return m === 0 ? `~${h}h` : `~${h}h ${m}m`;
}

// Parse the raw JSON into the typed shape, resolving each cut's method names to
// the method objects. A method name a cut references but the file doesn't
// define is a broken data file, so it throws rather than silently dropping the
// method and behaving differently from iOS.
export function parseCooking(root: unknown): CookingData {
  const r = root as Record<string, any>;
  const methods: CookMethod[] = (r.methods ?? []).map((m: any): CookMethod => ({
    name: String(m.name ?? ''),
    summary: String(m.summary ?? ''),
    steps: (m.steps ?? []).map((s: any): MethodStep => ({
      title: String(s.title ?? ''),
      detail: String(s.detail ?? ''),
      ...(typeof s.minutes === 'number' ? { minutes: s.minutes } : {}),
      ...(typeof s.grillTemp === 'number' ? { grillTemp: s.grillTemp } : {}),
    })),
    ...(typeof m.grillTemp === 'number' ? { grillTemp: m.grillTemp } : {}),
    ...(typeof m.note === 'string' ? { note: m.note } : {}),
  }));

  const byName = new Map(methods.map((m) => [m.name, m]));
  const cuts: MeatCut[] = (r.cuts ?? []).map((c: any): MeatCut => ({
    name: String(c.name ?? ''),
    category: (c.category ?? 'other') as MeatCategory,
    targets: (c.targets ?? []).map((t: any): MeatTarget => ({
      label: String(t.label ?? ''),
      temperature: Number(t.temperature ?? 0),
      kind: (t.kind ?? 'doneness') as TargetKind,
    })),
    ...(typeof c.note === 'string' ? { note: c.note } : {}),
    ...(typeof c.grillTemp === 'number' ? { grillTemp: c.grillTemp } : {}),
    methods: (c.methods ?? []).map((name: string) => {
      const m = byName.get(name);
      if (!m) throw new Error(`cooking.json: cut "${c.name}" references unknown method "${name}"`);
      return m;
    }),
    ...(typeof c.safeFloorOverride === 'number' ? { safeFloorOverride: c.safeFloorOverride } : {}),
  }));

  return {
    version: Number(r.version ?? 0),
    cuts,
    methods,
    safeMinimums: r.safeMinimums ?? {},
    ...(typeof r.note === 'string' ? { note: r.note } : {}),
  };
}

// The floor that applies to a cut.
export function safeFloor(cut: MeatCut, data: CookingData): number | null {
  return cut.safeFloorOverride ?? data.safeMinimums[cut.category] ?? null;
}

// The target to pre-select: the texture one for barbecue cuts, else the safe
// minimum, else the middle doneness.
export function suggestedTarget(cut: MeatCut): MeatTarget | null {
  return cut.targets.find((t) => t.kind === 'texture')
    ?? cut.targets.find((t) => t.kind === 'safeMinimum')
    ?? cut.targets[Math.floor(cut.targets.length / 2)]
    ?? cut.targets[0]
    ?? null;
}

export function cutsByCategory(data: CookingData, category: MeatCategory): MeatCut[] {
  return data.cuts.filter((c) => c.category === category);
}

export function findMethod(data: CookingData, name: string): CookMethod {
  const m = data.methods.find((x) => x.name === name);
  if (!m) throw new Error(`cooking.json has no method named '${name}'`);
  return m;
}

// Whether a target sits under the floor that applies.
//
// This is a warning, not a veto: doneness temperatures for whole-muscle beef
// and lamb legitimately sit below the USDA figure and plenty of cooks choose
// them knowingly. The point is that the choice is visible, not that it's
// blocked.
export function isBelowSafeMinimumForCategory(
  target: MeatTarget, category: MeatCategory, data: CookingData,
): boolean {
  const floor = data.safeMinimums[category];
  return floor !== undefined && target.temperature < floor;
}

export function isBelowSafeMinimum(target: MeatTarget, cut: MeatCut, data: CookingData): boolean {
  const floor = safeFloor(cut, data);
  return floor !== null && target.temperature < floor;
}

// Case-insensitive search across cut name and category. An empty query returns
// everything, so the picker can use one code path for browsing and searching.
export function searchCuts(data: CookingData, query: string): MeatCut[] {
  const q = query.trim().toLowerCase();
  if (q === '') return data.cuts;
  return data.cuts.filter(
    (c) => c.name.toLowerCase().includes(q)
      || c.category.toLowerCase().includes(q)
      || CATEGORY_LABELS[c.category].toLowerCase().includes(q),
  );
}

// Cuts that carry a conventional grill temperature, so selecting one can set
// the grill as well as the probe target — the "cook preset".
export function presetableCuts(data: CookingData): MeatCut[] {
  return data.cuts.filter((c) => typeof c.grillTemp === 'number');
}
