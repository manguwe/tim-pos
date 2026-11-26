/**
 * Shop settings the owner can change. Reference implementation; app/lib/settings/settings_repository.dart is a port.
 *
 * Only the keys listed in SETTINGS can be changed here (costing and the ZIMRA switch are not on the list on purpose).
 * Values are stored as text in the `settings` table (scope 'shop'); a key with no row uses its default.
 */
import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { Writer, tx, SetupError, type SetupContext } from './setup.ts';
import { hasPermission } from './auth.ts';

export interface SettingDef { key: string; group: string; label: string; help: string; kind: 'bool' | 'int' | 'text'; default: string; min?: number; max?: number; max_len?: number; digits?: number }

export const SETTINGS: SettingDef[] = [
  { key: 'require_shift', group: 'Selling', label: 'Cashiers must open a shift before selling', help: 'Every sale is then tied to a shift, so cash-up can account for it.', kind: 'bool', default: '0' },
  { key: 'allow_negative_stock', group: 'Selling', label: 'Allow selling when stock shows zero', help: 'Off by default: a sale is blocked when there is not enough stock. Turn on only if you do not keep stock counts up to date.', kind: 'bool', default: '0' },
  { key: 'layby_min_deposit_pct', group: 'Selling', label: 'Minimum layby deposit (%)', help: 'The share of the total a customer must pay when starting a layby. 0 means no minimum.', kind: 'int', default: '0', min: 0, max: 100 },
  { key: 'receipt_shop_name', group: 'Receipts', label: 'Name on the receipt', help: 'Leave empty to print your shop name as it is on your licence.', kind: 'text', default: '', max_len: 40 },
  { key: 'receipt_address', group: 'Receipts', label: 'Address on the receipt', help: 'Street and town. Leave empty to print nothing.', kind: 'text', default: '', max_len: 100 },
  { key: 'receipt_phone', group: 'Receipts', label: 'Phone number on the receipt', help: 'For example 0772 123 456.', kind: 'text', default: '', max_len: 30 },
  { key: 'receipt_header', group: 'Receipts', label: 'Receipt header', help: 'A line printed under the shop name, for example a slogan.', kind: 'text', default: '', max_len: 120 },
  { key: 'receipt_footer', group: 'Receipts', label: 'Receipt footer', help: 'Printed at the bottom of receipts and slips, for example your returns policy.', kind: 'text', default: '', max_len: 120 },
  { key: 'receipt_thanks', group: 'Receipts', label: 'Last line', help: 'The very last line, for example "Thank you, come again". Clear it to print nothing.', kind: 'text', default: 'Thank you', max_len: 60 },
  { key: 'receipt_show_cashier', group: 'Receipts', label: "Print the cashier's name", help: 'Shows who served the customer.', kind: 'bool', default: '1' },
  { key: 'receipt_show_customer', group: 'Receipts', label: "Print the customer's name", help: 'Only when a customer was chosen on the sale.', kind: 'bool', default: '1' },
  { key: 'low_stock_level', group: 'Stock', label: 'Low-stock warning level', help: 'Items with this many or fewer left show on the Low stock list. 0 turns the warning off.', kind: 'int', default: '5', min: 0, max: 100000 },
  { key: 'scale_prefix', group: 'Barcodes', label: 'Scale label prefix', help: 'Two digits. Fill in only if you have a shop scale that prints weight labels. Leave empty if not.', kind: 'text', default: '', max_len: 2, digits: 2 },
];

type Row = Record<string, any>;

export function getSettings(db: DatabaseSync): Record<string, string> {
  const out: Record<string, string> = Object.fromEntries(SETTINGS.map((d) => [d.key, d.default]));
  for (const r of db.prepare("select key, value from settings where scope = 'shop' and deleted_at is null").all() as Row[]) {
    if (r.key in out && typeof r.value === 'string') out[r.key] = r.value;
  }
  return out;
}

/** Checks one value and returns it in the form that is stored. */
export function normaliseSetting(def: SettingDef, raw: string): string {
  const v = String(raw ?? '');
  if (def.kind === 'bool') {
    if (v !== '0' && v !== '1') throw new SetupError('bad_setting', `${def.label}: choose on or off.`);
    return v;
  }
  if (def.kind === 'int') {
    const t = v.trim();
    if (!/^\d{1,9}$/.test(t)) throw new SetupError('bad_setting', `${def.label}: enter a whole number.`);
    const n = Number(t);
    if (n < (def.min ?? 0) || n > (def.max ?? 1_000_000_000)) throw new SetupError('bad_setting', `${def.label}: enter a number from ${def.min ?? 0} to ${def.max}.`);
    return String(n);
  }
  const t = v.replace(/\s+/g, ' ').trim();
  if (def.digits && t !== '' && !new RegExp(`^\\d{${def.digits}}$`).test(t)) throw new SetupError('bad_setting', `${def.label}: enter exactly ${def.digits} digits, or leave it empty.`);
  if (t.length > (def.max_len ?? 200)) throw new SetupError('bad_setting', `${def.label}: use at most ${def.max_len} characters.`);
  return t;
}

/** Saves the changed values. Everything is checked first, so nothing is saved if one value is wrong. Returns the keys that changed. */
export function saveSettings(db: DatabaseSync, ctx: SetupContext, changes: Record<string, string>, newId: () => string = randomUUID): string[] {
  if (ctx.user_id && !hasPermission(db, ctx.user_id, 'settings.edit')) throw new SetupError('forbidden', 'You are not allowed to change settings.');
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    const cur = getSettings(db);
    const todo: { def: SettingDef; value: string }[] = [];
    for (const [key, raw] of Object.entries(changes)) {
      const def = SETTINGS.find((d) => d.key === key);
      if (!def) throw new SetupError('unknown_setting', 'That setting does not exist.');
      const value = normaliseSetting(def, raw);
      if (value !== cur[key]) todo.push({ def, value });
    }
    for (const { def, value } of todo) {
      const row = w.get("select id from settings where scope = 'shop' and key = ? and deleted_at is null", def.key);
      if (row) w.edit('settings', row.id, { value });
      else w.addVersioned('settings', { scope: 'shop', key: def.key, value });
      w.add('audit_log', { user_id: ctx.user_id, action: 'setting_change', table_name: 'settings', row_id: def.key, before: cur[def.key], after: value });
    }
    return todo.map((t) => t.def.key);
  });
}
