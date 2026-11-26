-- Daily or weekly report messages to the shop owner, set up by the owner.
create table digest_settings (
  tenant_id text primary key references tenants(id),
  channel text not null default 'whatsapp' check (channel in ('whatsapp', 'telegram')),
  recipient text not null default '',          -- phone number with country code, or a Telegram chat id
  frequency text not null default 'off' check (frequency in ('off', 'daily', 'weekly')),
  send_hour integer not null default 20 check (send_hour between 0 and 23),
  weekday integer not null default 0 check (weekday between 0 and 6),   -- 0 = Sunday, used for weekly
  utc_offset_min integer not null default 120,
  last_sent_key text not null default '',
  last_error text not null default '',
  updated_at integer not null
);
