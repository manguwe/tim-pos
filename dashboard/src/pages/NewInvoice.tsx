import { useState } from 'react';
import { api, type BillingProfile, type Plan, type ShopRow } from '../api.ts';
import { isoOf, money, parseMoney, dayStart, plainAmount, pct } from '../format.ts';
import { navigate } from '../router.tsx';
import { Button, Field, FormModal, useAsync, useToast } from '../ui.tsx';

interface Row { description: string; quantity: string; price: string; kind: 'one_time' | 'monthly' | 'other'; licence_id: string | null }

/** Make an invoice for a shop. Lines can be filled from a plan. Amounts are typed in whole units, like 25 or 25.50. */
export function NewInvoice({ shopId, onClose, onDone }: { shopId?: string; onClose: () => void; onDone?: () => void }) {
  const toast = useToast();
  const shops = useAsync(() => (shopId ? Promise.resolve({ tenants: [] as ShopRow[] }) : api<{ tenants: ShopRow[] }>('GET', '/tenants')), [shopId]);
  const plans = useAsync(() => api<{ plans: Plan[] }>('GET', '/plans'), []);
  const profile = useAsync(() => api<BillingProfile>('GET', '/billing/profile'), []);
  const [shop, setShop] = useState(shopId ?? '');
  const [currency, setCurrency] = useState('USD');
  const [rows, setRows] = useState<Row[]>([{ description: '', quantity: '1', price: '', kind: 'other', licence_id: null }]);
  const [planId, setPlanId] = useState('');
  const [months, setMonths] = useState('1');
  const [due, setDue] = useState('');
  const [tax, setTax] = useState<string | null>(null);
  const [notes, setNotes] = useState('');

  const taxPct = tax ?? String((profile.data?.default_tax_bp ?? 0) / 100);
  const dueDefault = isoOf(Date.now() + (profile.data?.default_due_days ?? 14) * 86_400_000);
  const update = (i: number, patch: Partial<Row>) => setRows((r) => r.map((x, j) => (j === i ? { ...x, ...patch } : x)));

  const fromPlan = (withOnce: boolean) => {
    const p = plans.data?.plans.find((x) => x.id === planId);
    if (!p) return;
    const n = Math.max(1, Math.min(120, Number(months) || 1));
    const add: Row[] = [];
    if (withOnce && p.one_time_fee_minor > 0) add.push({ description: `Set-up fee (${p.name})`, quantity: '1', price: plainAmount(p.one_time_fee_minor), kind: 'one_time', licence_id: null });
    if (p.monthly_fee_minor > 0) add.push({ description: `Monthly licence fee (${p.name})`, quantity: String(n), price: plainAmount(p.monthly_fee_minor), kind: 'monthly', licence_id: null });
    setCurrency(p.currency);
    setRows((r) => [...r.filter((x) => x.description.trim() || x.price.trim()), ...add]);
  };

  const parsed = rows.map((r) => ({ q: Number(r.quantity), p: parseMoney(r.price) }));
  const subtotal = parsed.reduce((s, x, i) => s + (Number.isInteger(x.q) && x.q > 0 && x.p !== null && rows[i]?.description.trim() ? x.q * x.p : 0), 0);
  const taxBp = Math.round(Number(taxPct) * 100);
  const taxMinor = Number.isFinite(taxBp) ? Math.floor((subtotal * taxBp + 5000) / 10000) : 0;

  return (
    <FormModal
      title="New invoice"
      submit="Create invoice"
      wide
      onClose={onClose}
      onSubmit={async () => {
        if (!shop) throw new Error('Choose the shop.');
        const lines = rows.filter((r) => r.description.trim() || r.price.trim()).map((r, i) => {
          const price = parseMoney(r.price);
          const q = Number(r.quantity);
          if (!r.description.trim()) throw new Error(`Line ${i + 1}: add a description.`);
          if (price === null) throw new Error(`Line ${i + 1}: the price must look like 25 or 25.50.`);
          if (!Number.isInteger(q) || q < 1) throw new Error(`Line ${i + 1}: the quantity must be a whole number.`);
          return { description: r.description.trim(), quantity: q, unit_price_minor: price, kind: r.kind, ...(r.licence_id ? { licence_id: r.licence_id } : {}) };
        });
        if (lines.length === 0) throw new Error('Add at least one line.');
        if (!Number.isFinite(taxBp) || taxBp < 0 || taxBp > 10000) throw new Error('Tax must be between 0 and 100.');
        const dueAt = dayStart(due || dueDefault);
        const r = await api<{ id: string; number: string }>('POST', `/tenants/${shop}/invoices`, {
          currency: currency.toUpperCase(), lines, tax_bp: taxBp, ...(dueAt ? { due_at: dueAt } : {}), ...(notes.trim() ? { notes } : {}),
        });
        toast(`Invoice ${r.number} created.`);
        onDone?.();
        onClose();
        navigate(`/invoices/${r.id}`);
      }}
    >
      {!shopId && (
        <Field label="Shop">
          {(id) => (
            <select id={id} required value={shop} onChange={(e) => setShop(e.target.value)}>
              <option value="">Choose a shop…</option>
              {(shops.data?.tenants ?? []).map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
          )}
        </Field>
      )}
      <div className="grid2">
        <Field label="Currency">{(id) => <input id={id} required minLength={3} maxLength={3} value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())} />}</Field>
        <Field label="Due date" hint={`Default: ${profile.data?.default_due_days ?? 14} days from today.`}>{(id) => <input id={id} type="date" value={due || dueDefault} onChange={(e) => setDue(e.target.value)} />}</Field>
      </div>
      <fieldset className="plan-fill">
        <legend>Fill from a plan</legend>
        <select aria-label="Plan" value={planId} onChange={(e) => setPlanId(e.target.value)}>
          <option value="">Choose a plan…</option>
          {(plans.data?.plans ?? []).map((p) => <option key={p.id} value={p.id}>{p.name} ({money(p.monthly_fee_minor, p.currency)} / month)</option>)}
        </select>
        <input aria-label="Months to bill" type="number" min={1} max={120} value={months} onChange={(e) => setMonths(e.target.value)} />
        <span className="muted">months</span>
        <Button type="button" small disabled={!planId} onClick={() => fromPlan(true)}>Set-up fee and months</Button>
        <Button type="button" small disabled={!planId} onClick={() => fromPlan(false)}>Months only</Button>
      </fieldset>

      <div className="lines">
        <div className="line-head"><span>Description</span><span>Qty</span><span>Unit price</span><span /></div>
        {rows.map((r, i) => (
          <div className="line" key={i}>
            <input aria-label={`Description ${i + 1}`} maxLength={200} value={r.description} onChange={(e) => update(i, { description: e.target.value })} />
            <input aria-label={`Quantity ${i + 1}`} inputMode="numeric" value={r.quantity} onChange={(e) => update(i, { quantity: e.target.value })} />
            <input aria-label={`Unit price ${i + 1}`} inputMode="decimal" placeholder="0.00" value={r.price} onChange={(e) => update(i, { price: e.target.value })} />
            <button type="button" className="icon-btn" aria-label={`Remove line ${i + 1}`} disabled={rows.length === 1} onClick={() => setRows((x) => x.filter((_, j) => j !== i))}>×</button>
          </div>
        ))}
        <Button type="button" small onClick={() => setRows((r) => [...r, { description: '', quantity: '1', price: '', kind: 'other', licence_id: null }])}>Add a line</Button>
      </div>

      <div className="grid2">
        <Field label="Tax (%)" hint="Added to the total. Leave 0 if you do not charge tax.">{(id) => <input id={id} inputMode="decimal" value={taxPct} onChange={(e) => setTax(e.target.value)} />}</Field>
        <div className="totals" aria-live="polite">
          <div><span>Subtotal</span><span>{money(subtotal, currency || 'USD')}</span></div>
          <div><span>Tax {Number.isFinite(taxBp) ? pct(taxBp) : ''}</span><span>{money(taxMinor, currency || 'USD')}</span></div>
          <div className="grand"><span>Total</span><span>{money(subtotal + taxMinor, currency || 'USD')}</span></div>
        </div>
      </div>
      <Field label="Note on the invoice (optional)">{(id) => <textarea id={id} rows={2} maxLength={1000} value={notes} onChange={(e) => setNotes(e.target.value)} />}</Field>
    </FormModal>
  );
}
