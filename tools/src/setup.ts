/**
 * Shop set-up and catalogue: the writes behind the set-up and product screens. Reference implementation;
 * app/lib/setup/setup_repository.dart is a port. Everything is written through the normal tables, so the
 * database triggers log each row for sync and the other phones receive the same set-up.
 */
import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { DEFAULT_ROLES, ROLE_NAMES, hashPin, validatePin } from './auth.ts';

export interface SetupContext { shop_id: string; device_id: string; user_id: string | null; now: number }
export class SetupError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

export interface CountryPreset {
  base_currency: string;
  currencies: { code: string; name: string; symbol: string; minor_units: number; rounding_increment_minor: number }[];
  payment_methods: { code: string; name: string; kind: string; requires_reference: number; opens_drawer: number }[];
  tax_classes: { name: string; rate_bp: number; is_inclusive: number }[];
}

const COMMON_METHODS = [
  { code: 'cash', name: 'Cash', kind: 'cash', requires_reference: 0, opens_drawer: 1 },
  { code: 'card', name: 'Card', kind: 'card', requires_reference: 1, opens_drawer: 0 },
  { code: 'bank_transfer', name: 'Bank transfer', kind: 'bank', requires_reference: 1, opens_drawer: 0 },
];
const mm = (code: string, name: string) => ({ code, name, kind: 'mobile_money', requires_reference: 1, opens_drawer: 0 });

/** Starting points per country. Everything here can be changed by the shop afterwards. Tax rates are defaults, not advice. */
export const PRESETS: Record<string, CountryPreset> = {
  ZW: {
    base_currency: 'USD',
    currencies: [
      { code: 'USD', name: 'US dollar', symbol: '$', minor_units: 2, rounding_increment_minor: 5 },
      { code: 'ZiG', name: 'Zimbabwe Gold', symbol: 'ZiG', minor_units: 2, rounding_increment_minor: 100 },
    ],
    payment_methods: [...COMMON_METHODS.slice(0, 1), mm('ecocash', 'EcoCash'), mm('onemoney', 'OneMoney'), mm('innbucks', 'InnBucks'), ...COMMON_METHODS.slice(1)],
    tax_classes: [{ name: 'Standard rated', rate_bp: 1500, is_inclusive: 1 }, { name: 'Zero rated', rate_bp: 0, is_inclusive: 1 }, { name: 'Exempt', rate_bp: 0, is_inclusive: 1 }],
  },
  ZM: {
    base_currency: 'ZMW',
    currencies: [
      { code: 'ZMW', name: 'Zambian kwacha', symbol: 'K', minor_units: 2, rounding_increment_minor: 10 },
      { code: 'USD', name: 'US dollar', symbol: '$', minor_units: 2, rounding_increment_minor: 5 },
    ],
    payment_methods: [...COMMON_METHODS.slice(0, 1), mm('mtn_momo', 'MTN MoMo'), mm('airtel_money', 'Airtel Money'), ...COMMON_METHODS.slice(1)],
    tax_classes: [{ name: 'Standard rated', rate_bp: 1600, is_inclusive: 1 }, { name: 'Zero rated', rate_bp: 0, is_inclusive: 1 }, { name: 'Exempt', rate_bp: 0, is_inclusive: 1 }],
  },
};

type Row = Record<string, any>;

export class Writer {
  db: DatabaseSync; ctx: SetupContext; newId: () => string;
  constructor(db: DatabaseSync, ctx: SetupContext, newId: () => string) { this.db = db; this.ctx = ctx; this.newId = newId; }
  get(sql: string, ...a: any[]): Row | undefined { const r = this.db.prepare(sql).get(...a); return r ? { ...r } : undefined; }
  all(sql: string, ...a: any[]): Row[] { return this.db.prepare(sql).all(...a).map((r) => ({ ...r })); }
  run(sql: string, ...a: any[]) { this.db.prepare(sql).run(...a); }
  /** Adds a new row to a versioned table. */
  addVersioned(table: string, row: Row): string {
    return this.add(table, { updated_at: this.ctx.now, version: 1, ...row });
  }
  add(table: string, row: Row): string {
    const o: Row = { id: this.newId(), shop_id: this.ctx.shop_id, created_at: this.ctx.now, created_by: this.ctx.user_id, device_id: this.ctx.device_id, ...row };
    const k = Object.keys(o);
    this.run(`insert into "${table}" (${k.map((x) => `"${x}"`).join(', ')}) values (${k.map(() => '?').join(', ')})`, ...k.map((x) => o[x]));
    return o.id;
  }
  /** Edits a versioned row: the version rises by one, as the sync rules require. */
  edit(table: string, id: string, set: Row) {
    const cur = this.get(`select version from "${table}" where id = ?`, id);
    if (!cur) throw new SetupError('not_found', 'That record was not found.');
    const o: Row = { ...set, version: cur.version + 1, updated_at: this.ctx.now };
    const k = Object.keys(o);
    this.run(`update "${table}" set ${k.map((x) => `"${x}" = ?`).join(', ')} where id = ?`, ...k.map((x) => o[x]), id);
  }
}

export function tx<T>(db: DatabaseSync, fn: () => T): T {
  db.exec('begin');
  try { const r = fn(); db.exec('commit'); return r; } catch (e) { db.exec('rollback'); throw e; }
}

const need = (v: unknown, msg: string, code = 'missing') => { if (typeof v !== 'string' || v.trim() === '') throw new SetupError(code, msg); return v.trim(); };

/**
 * First-time set-up of a shop on this phone: the shop, its first branch and the country's currencies, payment methods,
 * tax classes, price tiers, units and default settings. Does nothing if the shop already exists (for example it arrived by sync).
 */
export function seedShop(db: DatabaseSync, ctx: SetupContext, input: { name: string; country_code: string; branch_name?: string; tax_registered?: boolean; tax_number?: string; owner?: { name: string; pin: string } }, newId: () => string = randomUUID): { branch_id: string; created: boolean; owner_id?: string } {
  const name = need(input.name, 'Enter the shop name.');
  const preset = PRESETS[input.country_code.toUpperCase()];
  if (!preset) throw new SetupError('unknown_country', 'That country has no preset yet.');
  const w = new Writer(db, ctx, newId);
  const ownerName = input.owner ? need(input.owner.name, 'Enter the owner\'s name.') : null;
  if (input.owner) { const bad = validatePin(input.owner.pin); if (bad) throw new SetupError('weak_pin', bad); }
  return tx(db, () => {
    const existing = w.get('select id from shops where deleted_at is null limit 1');
    if (existing) return { branch_id: (w.get('select id from branches where deleted_at is null order by created_at limit 1')?.id as string) ?? '', created: false };
    w.addVersioned('shops', { id: ctx.shop_id, name, country_code: input.country_code.toUpperCase(), base_currency: preset.base_currency, tax_registered: input.tax_registered ? 1 : 0, tax_number: input.tax_number ?? null });
    const branch = w.addVersioned('branches', { name: input.branch_name?.trim() || 'Main branch', is_active: 1 });
    for (const c of preset.currencies) w.addVersioned('currencies', { ...c, is_active: 1 });
    for (const m of preset.payment_methods) w.addVersioned('payment_methods', { ...m, is_active: 1 });
    for (const t of preset.tax_classes) w.addVersioned('tax_classes', t);
    w.addVersioned('price_tiers', { name: 'Retail', is_default: 1 });
    w.addVersioned('price_tiers', { name: 'Wholesale', is_default: 0 });
    for (const [n, c, k] of [['Piece', 'pcs', 'count'], ['Kilogram', 'kg', 'weight'], ['Litre', 'l', 'volume']]) w.addVersioned('units', { name: n, code: c, kind: k });
    for (const [key, value] of [['costing', 'weighted_average'], ['allow_negative_stock', '0'], ['fiscal_enabled', '0']]) w.addVersioned('settings', { scope: 'shop', key, value });
    const roleIds: Record<string, string> = {};
    for (const key of Object.keys(DEFAULT_ROLES) as (keyof typeof DEFAULT_ROLES)[]) {
      roleIds[key] = w.addVersioned('roles', { name: ROLE_NAMES[key], permissions: JSON.stringify(DEFAULT_ROLES[key]) });
    }
    let owner_id: string | undefined;
    if (input.owner) {
      owner_id = w.addVersioned('users', { name: ownerName, role_id: roleIds.owner, pin_hash: hashPin(input.owner.pin), is_active: 1 });
      w.addVersioned('user_branches', { user_id: owner_id, branch_id: branch });
    }
    return { branch_id: branch, created: true, owner_id };
  });
}

/** Sets today's rate: how many millionths of `to` one `from` is worth. A new row each time; history is kept. */
export function setExchangeRate(db: DatabaseSync, ctx: SetupContext, from: string, to: string, rateMicro: number, newId: () => string = randomUUID): void {
  if (from === to) throw new SetupError('same_currency', 'Choose two different currencies.');
  if (!Number.isSafeInteger(rateMicro) || rateMicro <= 0 || rateMicro > 100_000_000) throw new SetupError('bad_rate', 'That rate is not valid.');
  const w = new Writer(db, ctx, newId);
  for (const c of [from, to]) if (!w.get('select 1 as x from currencies where code = ? and deleted_at is null', c)) throw new SetupError('unknown_currency', `Currency ${c} is not set up.`);
  tx(db, () => w.add('exchange_rates', { from_currency: from, to_currency: to, rate_micro: rateMicro, set_by: ctx.user_id, effective_from: ctx.now }));
}

export interface ProductInput {
  id?: string;
  name: string;
  sku?: string | null;
  barcode?: string | null;
  price_minor?: number | null;
  price_currency?: string;
  cost_minor?: number | null;
  tax_class_id?: string | null;
  base_unit_id?: string | null;
  track_stock?: boolean;
  allow_negative_stock?: boolean;
  is_active?: boolean;
}

/**
 * Creates or edits a product. A changed price is a new price row with today's date, so earlier prices stay as history.
 * A barcode may belong to one product only.
 */
export function saveProduct(db: DatabaseSync, ctx: SetupContext, p: ProductInput, newId: () => string = randomUUID): string {
  const name = need(p.name, 'Enter the product name.');
  for (const [k, v] of [['price', p.price_minor], ['cost', p.cost_minor]] as const) {
    if (v != null && (!Number.isSafeInteger(v) || v < 0)) throw new SetupError('bad_amount', `The ${k} must be zero or more.`);
  }
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    const base = w.get('select base_currency from shops where deleted_at is null limit 1')?.base_currency as string | undefined;
    if (!base) throw new SetupError('shop_not_set_up', 'Set up the shop first.');
    const unit = p.base_unit_id ?? (w.get("select id from units where code = 'pcs' and deleted_at is null")?.id as string | undefined) ?? null;
    const fields: Row = {
      name, sku: p.sku?.trim() || null, base_unit_id: unit, tax_class_id: p.tax_class_id ?? null, kind: 'simple',
      track_stock: p.track_stock === false ? 0 : 1, allow_negative_stock: p.allow_negative_stock ? 1 : 0, is_active: p.is_active === false ? 0 : 1,
      cost_minor: p.cost_minor ?? null, cost_currency: base,
    };
    let id = p.id;
    if (id) w.edit('products', id, fields); else id = w.addVersioned('products', fields);

    if (p.barcode?.trim()) {
      const code = p.barcode.trim();
      const owner = w.get('select product_id from product_barcodes where barcode = ? and deleted_at is null', code);
      if (owner && owner.product_id !== id) throw new SetupError('barcode_taken', 'That barcode already belongs to another product.');
      if (!owner) w.addVersioned('product_barcodes', { product_id: id, barcode: code });
    }
    if (p.price_minor != null) {
      const cur = p.price_currency ?? base;
      const tier = (w.get('select id from price_tiers where is_default = 1 and deleted_at is null')?.id as string | undefined) ?? null;
      const last = w.get('select price_minor from product_prices where product_id = ? and currency = ? and tier_id is ? and deleted_at is null order by effective_from desc, created_at desc limit 1', id, cur, tier);
      if (!last || last.price_minor !== p.price_minor) {
        w.addVersioned('product_prices', { product_id: id, tier_id: tier, currency: cur, price_minor: p.price_minor, effective_from: ctx.now });
      }
    }
    return id;
  });
}

/**
 * Stock arriving: opening stock or a purchase. Writes the movement and, for purchases at a known cost, moves the product's
 * cost to the weighted average of what is on the shelf and what arrived. Costs are in the shop's base currency.
 */
export function receiveStock(
  db: DatabaseSync, ctx: SetupContext,
  r: { branch_id: string; product_id: string; qty_milli: number; unit_cost_minor?: number | null; opening?: boolean; batch_id?: string | null },
  newId: () => string = randomUUID,
): void {
  const w = new Writer(db, ctx, newId);
  tx(db, () => { stockIn(db, w, r); });
}

/**
 * The inside of receiveStock, for callers that already hold a transaction (goods received uses it).
 * Writes the movement and moves the product's cost; returns the movement id.
 */
export function stockIn(
  db: DatabaseSync, w: Writer,
  r: { branch_id: string; product_id: string; qty_milli: number; unit_cost_minor?: number | null; opening?: boolean; batch_id?: string | null; ref_type?: string | null; ref_id?: string | null; reason?: string | null },
): string {
  if (!Number.isSafeInteger(r.qty_milli) || r.qty_milli <= 0) throw new SetupError('bad_quantity', 'Quantity must be more than zero.');
  if (r.unit_cost_minor != null && (!Number.isSafeInteger(r.unit_cost_minor) || r.unit_cost_minor < 0)) throw new SetupError('bad_amount', 'The cost must be zero or more.');
  const p = w.get('select * from products where id = ? and deleted_at is null', r.product_id);
  if (!p) throw new SetupError('not_found', 'That product was not found.');
  const base = w.get('select base_currency from shops where deleted_at is null limit 1')?.base_currency as string;
  const onHand = (w.get('select coalesce(sum(qty_milli), 0) as q from stock_levels where product_id = ?', r.product_id)?.q as number) ?? 0;
  const id = w.add('stock_movements', { branch_id: r.branch_id, product_id: r.product_id, batch_id: r.batch_id ?? null, type: r.opening ? 'opening' : 'purchase', qty_milli: r.qty_milli, unit_cost_minor: r.unit_cost_minor ?? null, cost_currency: base, ref_type: r.ref_type ?? null, ref_id: r.ref_id ?? null, reason: r.reason ?? null });
  if (r.unit_cost_minor != null) {
    const costing = w.get("select value from settings where scope = 'shop' and key = 'costing' and deleted_at is null")?.value;
    const old = p.cost_minor as number | null;
    let next = r.unit_cost_minor;
    if (costing !== 'latest' && onHand > 0 && old != null) {
      const num = onHand * old + r.qty_milli * r.unit_cost_minor;
      const den = onHand + r.qty_milli;
      if (Number.isSafeInteger(num * 2 + den)) next = Math.floor((num * 2 + den) / (den * 2)); // half up, whole cents
    }
    if (next !== old) w.edit('products', r.product_id, { cost_minor: next, cost_currency: base });
  }
  return id;
}
