-- How many AI requests each shop has used this month. The vendor sets the limit; the feature itself is a licence option called "ai".
create table ai_usage (
  shop_id text not null references tenants (id),
  month text not null,        -- for example 2026-11 (UTC)
  kind text not null check (kind in ('suggest', 'ask')),
  n integer not null default 0,
  primary key (shop_id, month, kind)
);
