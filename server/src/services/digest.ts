import type { Ctx } from '../context.ts';
import { HttpError, asObject, optInt, optStr } from '../http.ts';
import { shopView } from '../reports/engine.ts';
import * as R from '../reports/reports.ts';

export type Sender = (cfg: Ctx['config'], channel: 'whatsapp' | 'telegram', recipient: string, text: string) => Promise<void>;

/** Real sending. WhatsApp needs a Meta business account and an approved template; Telegram needs only a bot token. */
export const realSender: Sender = async (cfg, channel, recipient, text) => {
  if (channel === 'telegram') {
    if (!cfg.telegramBotToken) throw new Error('Telegram is not set up on the server (TELEGRAM_BOT_TOKEN).');
    const res = await fetch(`https://api.telegram.org/bot${cfg.telegramBotToken}/sendMessage`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, signal: AbortSignal.timeout(15_000),
      body: JSON.stringify({ chat_id: recipient, text }),
    });
    if (!res.ok) throw new Error(`Telegram answered ${res.status}`);
    return;
  }
  if (!cfg.whatsappToken || !cfg.whatsappPhoneId) throw new Error('WhatsApp is not set up on the server (WHATSAPP_TOKEN and WHATSAPP_PHONE_ID).');
  // Template variables cannot contain new lines, so lines are joined with " | ".
  const flat = text.split('\n').filter(Boolean).join(' | ');
  const res = await fetch(`https://graph.facebook.com/v21.0/${cfg.whatsappPhoneId}/messages`, {
    method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${cfg.whatsappToken}` }, signal: AbortSignal.timeout(15_000),
    body: JSON.stringify({
      messaging_product: 'whatsapp', to: recipient.replace(/\D/g, ''), type: 'template',
      template: { name: cfg.whatsappTemplate ?? 'shop_report', language: { code: cfg.whatsappLang ?? 'en' },
        components: [{ type: 'body', parameters: [{ type: 'text', text: flat }] }] },
    }),
  });
  if (!res.ok) throw new Error(`WhatsApp answered ${res.status}`);
};

const money = (minor: number, cur: string) => `${cur} ${(minor / 100).toFixed(2)}`;
const localDate = (ms: number, off: number) => new Date(ms + off * 60_000).toISOString().slice(0, 10);

interface Settings {
  tenant_id: string; channel: 'whatsapp' | 'telegram'; recipient: string; frequency: 'off' | 'daily' | 'weekly';
  send_hour: number; weekday: number; utc_offset_min: number; last_sent_key: string; last_error: string; updated_at: number;
}

/** The text of one report. Period is the local day so far (daily) or the last 7 local days (weekly). */
export function buildDigest(ctx: Ctx, tenantId: string, frequency: 'daily' | 'weekly', off: number): string {
  const now = ctx.now();
  const dayStart = Date.parse(`${localDate(now, off)}T00:00:00Z`) - off * 60_000;
  const range: R.Range = frequency === 'daily' ? { from: dayStart, to: Math.max(now, dayStart + 1) } : { from: dayStart - 6 * 86_400_000, to: Math.max(now, dayStart + 1) };
  const db = shopView(ctx.db, tenantId, now).db;
  const name = ctx.db.get<{ name: string }>('select name from tenants where id = ?', tenantId)?.name ?? 'Your shop';
  const s = R.salesSummary(db, range);
  const cur = s.base_currency;
  const top = R.topProducts(db, range, { by: 'revenue', limit: 3 });
  const lines = [
    `${name}: ${frequency === 'daily' ? "today's" : 'last 7 days'} report (${localDate(range.from, off)}${frequency === 'weekly' ? ` to ${localDate(now, off)}` : ''})`,
    `Sales: ${s.sales}`,
    `Revenue: ${money(s.revenue_minor, cur)}`,
    `Profit: ${money(s.profit_minor, cur)}${s.lines_without_cost ? ' (some items have no cost set)' : ''}`,
  ];
  if (top.length) lines.push(`Top: ${top.map((t) => `${t.name} (${money(t.revenue_minor, cur)})`).join(', ')}`);
  return lines.join('\n');
}

export function getSettings(ctx: Ctx, tenantId: string): Settings {
  return ctx.db.get<Settings>('select * from digest_settings where tenant_id = ?', tenantId) ?? {
    tenant_id: tenantId, channel: 'whatsapp', recipient: '', frequency: 'off', send_hour: 20, weekday: 0,
    utc_offset_min: 120, last_sent_key: '', last_error: '', updated_at: 0,
  };
}

export function saveSettings(ctx: Ctx, tenantId: string, body: unknown): Settings {
  const o = asObject(body);
  const cur = getSettings(ctx, tenantId);
  const channel = (optStr(o, 'channel', 12) ?? cur.channel) as string;
  const frequency = (optStr(o, 'frequency', 12) ?? cur.frequency) as string;
  if (channel !== 'whatsapp' && channel !== 'telegram') throw new HttpError(400, 'invalid_request', 'channel must be whatsapp or telegram');
  if (frequency !== 'off' && frequency !== 'daily' && frequency !== 'weekly') throw new HttpError(400, 'invalid_request', 'frequency must be off, daily or weekly');
  const recipient = (optStr(o, 'recipient', 40) ?? cur.recipient).trim();
  if (frequency !== 'off' && !recipient) throw new HttpError(400, 'invalid_request', 'Enter where to send the report');
  if (channel === 'whatsapp' && recipient && !/^\+?\d{8,15}$/.test(recipient.replace(/[\s-]/g, ''))) {
    throw new HttpError(400, 'invalid_request', 'Enter the WhatsApp number with its country code, for example +263771234567');
  }
  const next = {
    send_hour: optInt(o, 'send_hour', { min: 0, max: 23 }) ?? cur.send_hour,
    weekday: optInt(o, 'weekday', { min: 0, max: 6 }) ?? cur.weekday,
    utc_offset_min: optInt(o, 'utc_offset_min', { min: -720, max: 840 }) ?? cur.utc_offset_min,
  };
  ctx.db.run(
    `insert into digest_settings (tenant_id, channel, recipient, frequency, send_hour, weekday, utc_offset_min, updated_at)
     values (?, ?, ?, ?, ?, ?, ?, ?)
     on conflict(tenant_id) do update set channel = excluded.channel, recipient = excluded.recipient, frequency = excluded.frequency,
       send_hour = excluded.send_hour, weekday = excluded.weekday, utc_offset_min = excluded.utc_offset_min, updated_at = excluded.updated_at`,
    tenantId, channel, recipient.replace(/[\s-]/g, ''), frequency, next.send_hour, next.weekday, next.utc_offset_min, ctx.now(),
  );
  return getSettings(ctx, tenantId);
}

/** Sends a report right now so the owner can check it arrives. */
export async function sendTest(ctx: Ctx, tenantId: string, send: Sender = realSender): Promise<void> {
  const s = getSettings(ctx, tenantId);
  if (!s.recipient) throw new HttpError(400, 'invalid_request', 'Save where to send the report first');
  try {
    await send(ctx.config, s.channel, s.recipient, buildDigest(ctx, tenantId, s.frequency === 'weekly' ? 'weekly' : 'daily', s.utc_offset_min));
  } catch (e) {
    throw new HttpError(502, 'send_failed', (e as Error).message);
  }
}

/** Sends every report that is due. Called every few minutes. A failure is saved on the setting and retried next time. */
export async function runDue(ctx: Ctx, send: Sender = realSender): Promise<number> {
  let sent = 0;
  const rows = ctx.db.all<Settings>("select * from digest_settings where frequency != 'off' and recipient != ''");
  for (const s of rows) {
    const now = ctx.now();
    const local = new Date(now + s.utc_offset_min * 60_000);
    const key = localDate(now, s.utc_offset_min);
    if (local.getUTCHours() < s.send_hour || s.last_sent_key === key) continue;
    if (s.frequency === 'weekly' && local.getUTCDay() !== s.weekday) continue;
    const live = ctx.db.get<{ n: number }>(
      `select count(*) as n from licences l join tenants t on t.id = l.tenant_id
       where l.tenant_id = ? and l.status = 'active' and t.status = 'active' and l.expires_at + l.grace_days * 86400000 > ?`, s.tenant_id, now)?.n ?? 0;
    if (!live) continue;
    try {
      await send(ctx.config, s.channel, s.recipient, buildDigest(ctx, s.tenant_id, s.frequency as 'daily' | 'weekly', s.utc_offset_min));
      ctx.db.run("update digest_settings set last_sent_key = ?, last_error = '' where tenant_id = ?", key, s.tenant_id);
      sent++;
    } catch (e) {
      ctx.db.run('update digest_settings set last_error = ? where tenant_id = ?', (e as Error).message.slice(0, 200), s.tenant_id);
    }
  }
  return sent;
}

export function startDigests(ctx: Ctx, log: (m: string) => void): () => void {
  const t = setInterval(() => { runDue(ctx).then((n) => { if (n) log(`Sent ${n} report message(s)`); }).catch((e) => log(`Reports failed: ${(e as Error).message}`)); }, 5 * 60_000);
  t.unref();
  return () => clearInterval(t);
}

/** What the owner's settings page needs to know about what this server can send. */
export function available(ctx: Ctx): { whatsapp: boolean; telegram: boolean } {
  return { whatsapp: !!(ctx.config.whatsappToken && ctx.config.whatsappPhoneId), telegram: !!ctx.config.telegramBotToken };
}
