-- Vendor billing: what each shop owes TIM-POS (licence fees) and what it has paid.
-- Money is whole minor units (cents). An invoice and its payments are in one currency; nothing is converted.
-- Invoices and payments are never deleted. A mistake is a voided invoice or a reversed payment, with a reason.

create table billing_profile (
  id integer primary key check (id = 1),
  business_name text not null default '',
  address text not null default '',
  phone text not null default '',
  email text not null default '',
  tax_number text not null default '',
  default_tax_bp integer not null default 0 check (default_tax_bp between 0 and 10000),
  default_due_days integer not null default 14 check (default_due_days between 0 and 365),
  invoice_prefix text not null default 'INV',
  receipt_prefix text not null default 'RCT',
  payment_instructions text not null default '',
  footer text not null default '',
  updated_at integer not null default 0
);
insert into billing_profile (id) values (1);

-- One row per kind and year ('invoice:2026'), so numbers run 0001, 0002, ... with no gaps or repeats.
create table billing_counters (name text primary key, value integer not null);

create table invoices (
  id text primary key,
  number text not null unique,
  tenant_id text not null references tenants (id),
  currency text not null check (length(currency) = 3),
  status text not null default 'issued' check (status in ('issued', 'void')),
  issued_at integer not null,
  due_at integer not null,
  subtotal_minor integer not null check (subtotal_minor >= 0),
  tax_bp integer not null default 0 check (tax_bp between 0 and 10000),
  tax_minor integer not null default 0 check (tax_minor >= 0),
  total_minor integer not null check (total_minor > 0),
  notes text,
  void_reason text,
  voided_at integer,
  created_by text references vendor_users (id),
  created_at integer not null,
  check ((status = 'void') = (voided_at is not null))
);
create index invoices_tenant on invoices (tenant_id, issued_at);

create table invoice_lines (
  id text primary key,
  invoice_id text not null references invoices (id),
  description text not null,
  quantity integer not null check (quantity > 0),
  unit_price_minor integer not null check (unit_price_minor >= 0),
  line_total_minor integer not null check (line_total_minor >= 0),
  kind text not null default 'other' check (kind in ('one_time', 'monthly', 'other')),
  licence_id text references licences (id),
  -- Set by the monthly billing run so the same licence is never billed twice for one month. Cleared when the invoice is voided.
  period_key text
);
create index invoice_lines_invoice on invoice_lines (invoice_id);
create unique index invoice_lines_period on invoice_lines (licence_id, period_key) where period_key is not null;

create table payments (
  id text primary key,
  receipt_no text not null unique,
  invoice_id text not null references invoices (id),
  tenant_id text not null references tenants (id),
  currency text not null,
  amount_minor integer not null check (amount_minor > 0),
  method text not null check (method in ('cash', 'ecocash', 'onemoney', 'innbucks', 'bank', 'other')),
  reference text,
  note text,
  received_at integer not null,
  -- The dashboard sends one per form, so a double click or a retry cannot record the same payment twice.
  request_id text unique,
  extended_licence_id text references licences (id),
  extended_months integer,
  created_by text references vendor_users (id),
  created_at integer not null,
  reversed_at integer,
  reverse_reason text,
  reversed_by text references vendor_users (id),
  check ((reversed_at is null) = (reverse_reason is null))
);
create index payments_invoice on payments (invoice_id);
create index payments_tenant on payments (tenant_id, received_at);

create trigger payments_no_delete before delete on payments begin select raise(abort, 'payments are never deleted'); end;
create trigger payments_guard before update on payments
  when old.reversed_at is not null or new.id <> old.id or new.receipt_no <> old.receipt_no or new.invoice_id <> old.invoice_id
    or new.tenant_id <> old.tenant_id or new.currency <> old.currency or new.amount_minor <> old.amount_minor
    or new.method <> old.method or new.received_at <> old.received_at or new.created_at <> old.created_at
begin select raise(abort, 'a payment cannot be changed, only reversed'); end;

create trigger invoices_no_delete before delete on invoices begin select raise(abort, 'invoices are never deleted'); end;
create trigger invoices_guard before update on invoices
  when old.status = 'void' or new.id <> old.id or new.number <> old.number or new.tenant_id <> old.tenant_id or new.currency <> old.currency
    or new.issued_at <> old.issued_at or new.due_at <> old.due_at or new.subtotal_minor <> old.subtotal_minor or new.tax_bp <> old.tax_bp
    or new.tax_minor <> old.tax_minor or new.total_minor <> old.total_minor
begin select raise(abort, 'an invoice cannot be changed, only voided'); end;
create trigger invoice_lines_no_delete before delete on invoice_lines begin select raise(abort, 'invoice lines are never deleted'); end;
create trigger invoice_lines_guard before update on invoice_lines
  when new.id <> old.id or new.invoice_id <> old.invoice_id or new.description <> old.description or new.quantity <> old.quantity
    or new.unit_price_minor <> old.unit_price_minor or new.line_total_minor <> old.line_total_minor or new.kind <> old.kind
    or new.licence_id is not old.licence_id
begin select raise(abort, 'an invoice line cannot be changed'); end;
