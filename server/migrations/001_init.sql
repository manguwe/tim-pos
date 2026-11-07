-- TIM-POS server schema (SQLite dialect). A PostgreSQL port follows the same tables and columns.
-- Times are integer milliseconds since 1970 (UTC). JSON columns hold JSON text.

create table tenants (
  id text primary key,
  name text not null,
  country_code text not null,
  contact text,
  notes text,
  status text not null default 'active' check (status in ('active', 'suspended')),
  created_at integer not null
);

create table plans (
  id text primary key,
  name text not null unique,
  one_time_fee_minor integer not null default 0 check (one_time_fee_minor >= 0),
  monthly_fee_minor integer not null default 0 check (monthly_fee_minor >= 0),
  currency text not null default 'USD',
  max_devices integer not null default 1 check (max_devices >= 1),
  max_branches integer not null default 1 check (max_branches >= 1),
  features text not null default '[]',
  created_at integer not null
);

create table licences (
  id text primary key,
  tenant_id text not null references tenants (id),
  plan_id text references plans (id),
  key_hash text not null unique,
  key_hint text not null,
  status text not null default 'active' check (status in ('active', 'suspended')),
  issued_at integer not null,
  expires_at integer not null,
  grace_days integer not null default 30 check (grace_days >= 0),
  max_offline_days integer not null default 60 check (max_offline_days >= 1),
  max_devices integer not null default 1 check (max_devices >= 1),
  max_branches integer not null default 1 check (max_branches >= 1),
  features text not null default '[]',
  created_at integer not null
);
create index licences_tenant on licences (tenant_id);

create table activations (
  id text primary key,
  licence_id text not null references licences (id),
  tenant_id text not null references tenants (id),
  fingerprint text not null,
  device_name text not null,
  platform text not null,
  secret_hash text not null,
  app_version text,
  activated_at integer not null,
  last_seen_at integer,
  last_pull_seq integer not null default 0,
  released_at integer,
  blocked integer not null default 0
);
create unique index activations_active_fingerprint on activations (licence_id, fingerprint) where released_at is null;
create index activations_tenant on activations (tenant_id);

create table licence_tokens (
  id text primary key,
  licence_id text not null references licences (id),
  device_id text not null references activations (id),
  issued_at integer not null,
  expires_at integer not null
);

create table vendor_users (
  id text primary key,
  name text not null,
  email text not null unique,
  password_hash text not null,
  role text not null default 'admin',
  is_active integer not null default 1,
  totp_secret_sealed text,
  totp_pending_sealed text,
  totp_enabled integer not null default 0,
  totp_last_step integer not null default 0,
  created_at integer not null
);

create table vendor_audit_log (
  id text primary key,
  vendor_user_id text references vendor_users (id),
  action text not null,
  tenant_id text,
  detail text not null default '{}',
  created_at integer not null
);
create index vendor_audit_created on vendor_audit_log (created_at);
create trigger vendor_audit_no_update before update on vendor_audit_log begin select raise(abort, 'append-only table'); end;
create trigger vendor_audit_no_delete before delete on vendor_audit_log begin select raise(abort, 'append-only table'); end;

create table app_releases (
  id text primary key,
  version text not null,
  build_number integer not null unique,
  min_supported_build integer not null default 0,
  sha256 text not null,
  size_bytes integer not null,
  apk_url text not null,
  notes text,
  published_at integer not null
);

-- Current state of every synced row, by shop. Typed tables for reports come with the dashboard.
create table records (
  shop_id text not null references tenants (id),
  table_name text not null,
  row_id text not null,
  version integer not null,
  data text not null,
  deleted_at integer,
  updated_at integer not null,
  primary key (shop_id, table_name, row_id)
) without rowid;

-- Order in which every device pulls changes.
create table change_feed (
  seq integer primary key autoincrement,
  shop_id text not null references tenants (id),
  table_name text not null,
  row_id text not null,
  op text not null check (op in ('insert', 'update', 'delete')),
  version integer not null,
  data text not null,
  device_id text not null,
  received_at integer not null
);
create index change_feed_shop_seq on change_feed (shop_id, seq);
create trigger change_feed_no_update before update on change_feed begin select raise(abort, 'append-only table'); end;
create trigger change_feed_no_delete before delete on change_feed begin select raise(abort, 'append-only table'); end;

-- A batch ID seen before is acknowledged and ignored, which makes a resend safe.
-- Batch IDs belong to the phone that made them, and a reused ID with different content is refused.
create table processed_batches (
  shop_id text not null references tenants (id),
  device_id text not null,
  batch_id text not null,
  content_hash text not null,
  processed_at integer not null,
  accepted integer not null,
  primary key (shop_id, device_id, batch_id)
) without rowid;

-- sync_epoch changes after the server is restored from a backup, which tells every phone to pull again from the start.
create table meta (
  key text primary key,
  value text not null
) without rowid;
insert into meta (key, value) values ('sync_epoch', lower(hex(randomblob(16))));

-- The losing side of a reference-data conflict is kept, never silently dropped.
create table sync_conflicts (
  id integer primary key autoincrement,
  shop_id text not null references tenants (id),
  table_name text not null,
  row_id text not null,
  device_id text not null,
  incoming_version integer not null,
  incoming_data text not null,
  kept_version integer not null,
  received_at integer not null
);
create index sync_conflicts_shop on sync_conflicts (shop_id, received_at);
