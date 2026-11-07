/** Turns "today", "this month" and so on into a time range on the owner's own clock, which is the shop's clock. */
export type PeriodId = 'today' | 'yesterday' | '7d' | 'month' | 'last-month' | 'custom';
export const PERIODS: [PeriodId, string][] = [['today', 'Today'], ['yesterday', 'Yesterday'], ['7d', 'Last 7 days'], ['month', 'This month'], ['last-month', 'Last month'], ['custom', 'Choose dates']];

export interface Range { from: number; to: number; label: string }
const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
const addDays = (ms: number, n: number) => { const d = new Date(ms); return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n).getTime(); };

export function rangeFor(id: PeriodId, custom: { from: string; to: string }, now = new Date()): Range | null {
  const today = startOfDay(now);
  switch (id) {
    case 'today': return { from: today, to: addDays(today, 1), label: 'Today' };
    case 'yesterday': return { from: addDays(today, -1), to: today, label: 'Yesterday' };
    case '7d': return { from: addDays(today, -6), to: addDays(today, 1), label: 'The last 7 days' };
    case 'month': return { from: new Date(now.getFullYear(), now.getMonth(), 1).getTime(), to: addDays(today, 1), label: 'This month so far' };
    case 'last-month': return { from: new Date(now.getFullYear(), now.getMonth() - 1, 1).getTime(), to: new Date(now.getFullYear(), now.getMonth(), 1).getTime(), label: 'Last month' };
    case 'custom': {
      const f = /^\d{4}-\d{2}-\d{2}$/.test(custom.from) ? new Date(`${custom.from}T00:00:00`).getTime() : NaN;
      const t = /^\d{4}-\d{2}-\d{2}$/.test(custom.to) ? new Date(`${custom.to}T00:00:00`).getTime() : NaN;
      if (!Number.isFinite(f) || !Number.isFinite(t) || t < f) return null;
      const to = addDays(t, 1);
      if (to - f > 400 * 86_400_000) return null;
      return { from: f, to, label: `${custom.from} to ${custom.to}` };
    }
  }
}
/** Minutes east of UTC, the way the server's daily report wants it. */
export const offsetMinutes = (): number => -new Date().getTimezoneOffset();
export const localIso = (d = new Date()): string => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
