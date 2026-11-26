import type { Ctx } from '../context.ts';
import { HttpError } from '../http.ts';

export interface FxFetcher {
  (base: string): Promise<{ rates: Record<string, number>; updatedAt: number | null }>;
}

/** Free daily rates from open.er-api.com (no key). Their terms ask for a link to exchangerate-api.com where rates are shown. */
export const openErApi: FxFetcher = async (base) => {
  const res = await fetch(`https://open.er-api.com/v6/latest/${encodeURIComponent(base)}`, { signal: AbortSignal.timeout(15_000) });
  if (!res.ok) throw new Error(`rates provider answered ${res.status}`);
  const j = (await res.json()) as { result?: string; rates?: Record<string, unknown>; time_last_update_unix?: number };
  if (j.result !== 'success' || !j.rates) throw new Error('rates provider gave no rates');
  const rates: Record<string, number> = {};
  for (const [k, v] of Object.entries(j.rates)) if (/^[A-Z]{3}$/.test(k) && typeof v === 'number' && v > 0 && Number.isFinite(v)) rates[k] = v;
  return { rates, updatedAt: j.time_last_update_unix ? j.time_last_update_unix * 1000 : null };
};

const STALE_MS = 12 * 3_600_000;

export async function refreshRates(ctx: Ctx, fetcher: FxFetcher = openErApi, base = 'USD'): Promise<boolean> {
  const row = ctx.db.get<{ fetched_at: number }>('select fetched_at from fx_rates where base = ?', base);
  if (row && ctx.now() - row.fetched_at < STALE_MS) return false;
  const r = await fetcher(base);
  if (!Object.keys(r.rates).length) throw new Error('no usable rates');
  ctx.db.run(
    `insert into fx_rates (base, rates, source_updated_at, fetched_at) values (?, ?, ?, ?)
     on conflict(base) do update set rates = excluded.rates, source_updated_at = excluded.source_updated_at, fetched_at = excluded.fetched_at`,
    base, JSON.stringify(r.rates), r.updatedAt, ctx.now(),
  );
  return true;
}

/** What phones get. Works offline from the last saved copy; says plainly when there is none. */
export function currentRates(ctx: Ctx): { base: string; rates: Record<string, number>; fetched_at: number; source_updated_at: number | null; attribution: string } {
  const row = ctx.db.get<{ base: string; rates: string; fetched_at: number; source_updated_at: number | null }>("select * from fx_rates where base = 'USD'");
  if (!row) throw new HttpError(503, 'rates_unavailable', 'Live rates have not been fetched yet. Try again soon.');
  return {
    base: row.base, rates: JSON.parse(row.rates) as Record<string, number>, fetched_at: row.fetched_at,
    source_updated_at: row.source_updated_at, attribution: 'Rates By Exchange Rate API (exchangerate-api.com)',
  };
}

export function startRateRefresh(ctx: Ctx, log: (m: string) => void, fetcher: FxFetcher = openErApi): () => void {
  const tick = () => refreshRates(ctx, fetcher).then((d) => { if (d) log('Exchange rates updated'); }).catch((e) => log(`Exchange rates not updated: ${(e as Error).message}`));
  void tick();
  const t = setInterval(tick, 3_600_000);
  t.unref();
  return () => clearInterval(t);
}
