-- Shop owner logins. An owner sees only their own shop's reports. Vendors create and disable them.
create table owner_users (
  id text primary key,
  tenant_id text not null references tenants (id),
  name text not null,
  email text not null unique,
  password_hash text not null,
  is_active integer not null default 1,
  must_change_password integer not null default 1,
  token_version integer not null default 1,
  created_at integer not null,
  last_login_at integer
);
create index owner_users_tenant on owner_users (tenant_id);
