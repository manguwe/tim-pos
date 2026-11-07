-- Copy of the phone schema (tables, indexes and the stock-level trigger only). Made by scripts/copy-shop-schema.sh. Do not edit by hand.
-- ##
create table "shops" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "country_code" text not null,
  "base_currency" text not null,
  "tax_registered" integer check ("tax_registered" is null or "tax_registered" in (0, 1)),
  "tax_number" text,
  "settings" text
);
-- ##
create table "branches" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "address" text,
  "phone" text,
  "is_active" integer check ("is_active" is null or "is_active" in (0, 1))
);
-- ##
create table "roles" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "permissions" text
);
-- ##
create table "users" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "phone" text,
  "email" text,
  "role_id" text references "roles" (id) deferrable initially deferred,
  "pin_hash" text,
  "password_hash" text,
  "is_active" integer check ("is_active" is null or "is_active" in (0, 1)),
  "failed_attempts" integer check ("failed_attempts" is null or typeof("failed_attempts") = 'integer'),
  "locked_until" integer check ("locked_until" is null or typeof("locked_until") = 'integer')
);
-- ##
create table "user_branches" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "user_id" text not null references "users" (id) deferrable initially deferred,
  "branch_id" text not null references "branches" (id) deferrable initially deferred
);
-- ##
create unique index "user_branches_ix1" on "user_branches" ("shop_id", "user_id", "branch_id") where deleted_at is null;
-- ##
create table "approvals" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "action" text not null,
  "requested_by" text,
  "approved_by" text,
  "ref_type" text,
  "ref_id" text
);
-- ##
create table "audit_log" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "user_id" text,
  "action" text not null,
  "table_name" text,
  "row_id" text,
  "before" text,
  "after" text
);
-- ##
create index "audit_log_ix1" on "audit_log" ("created_at");
-- ##
create table "categories" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "parent_id" text references "categories" (id) deferrable initially deferred,
  "sort_order" integer check ("sort_order" is null or typeof("sort_order") = 'integer')
);
-- ##
create table "units" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "code" text not null,
  "kind" text check ("kind" is null or "kind" in ('count', 'weight', 'volume'))
);
-- ##
create table "tax_classes" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "rate_bp" integer not null check ("rate_bp" is null or typeof("rate_bp") = 'integer'),
  "is_inclusive" integer check ("is_inclusive" is null or "is_inclusive" in (0, 1))
);
-- ##
create table "products" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "sku" text,
  "category_id" text references "categories" (id) deferrable initially deferred,
  "brand" text,
  "base_unit_id" text references "units" (id) deferrable initially deferred,
  "tax_class_id" text references "tax_classes" (id) deferrable initially deferred,
  "is_active" integer check ("is_active" is null or "is_active" in (0, 1)),
  "track_stock" integer check ("track_stock" is null or "track_stock" in (0, 1)),
  "track_expiry" integer check ("track_expiry" is null or "track_expiry" in (0, 1)),
  "allow_negative_stock" integer check ("allow_negative_stock" is null or "allow_negative_stock" in (0, 1)),
  "parent_product_id" text references "products" (id) deferrable initially deferred,
  "kind" text check ("kind" is null or "kind" in ('simple', 'variant_parent', 'bundle')),
  "cost_minor" integer check ("cost_minor" is null or typeof("cost_minor") = 'integer'),
  "cost_currency" text,
  "image_ref" text
);
-- ##
create index "products_ix1" on "products" ("name");
-- ##
create index "products_ix2" on "products" ("sku");
-- ##
create table "product_units" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "product_id" text not null references "products" (id) deferrable initially deferred,
  "unit_id" text not null references "units" (id) deferrable initially deferred,
  "factor_milli" integer not null check ("factor_milli" is null or typeof("factor_milli") = 'integer')
);
-- ##
create table "product_barcodes" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "product_id" text not null references "products" (id) deferrable initially deferred,
  "unit_id" text references "units" (id) deferrable initially deferred,
  "barcode" text not null
);
-- ##
create unique index "product_barcodes_ix1" on "product_barcodes" ("shop_id", "barcode") where deleted_at is null;
-- ##
create index "product_barcodes_ix2" on "product_barcodes" ("product_id");
-- ##
create table "bundle_items" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "bundle_product_id" text not null references "products" (id) deferrable initially deferred,
  "component_product_id" text not null references "products" (id) deferrable initially deferred,
  "qty_milli" integer not null check ("qty_milli" is null or typeof("qty_milli") = 'integer')
);
-- ##
create table "price_tiers" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "is_default" integer check ("is_default" is null or "is_default" in (0, 1))
);
-- ##
create table "product_prices" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "product_id" text not null references "products" (id) deferrable initially deferred,
  "tier_id" text references "price_tiers" (id) deferrable initially deferred,
  "unit_id" text references "units" (id) deferrable initially deferred,
  "currency" text not null,
  "price_minor" integer not null check ("price_minor" is null or typeof("price_minor") = 'integer'),
  "effective_from" integer not null check ("effective_from" is null or typeof("effective_from") = 'integer')
);
-- ##
create index "product_prices_ix1" on "product_prices" ("product_id", "tier_id", "currency", "effective_from");
-- ##
create table "promotions" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "kind" text not null,
  "rules" text,
  "starts_at" integer check ("starts_at" is null or typeof("starts_at") = 'integer'),
  "ends_at" integer check ("ends_at" is null or typeof("ends_at") = 'integer'),
  "is_active" integer check ("is_active" is null or "is_active" in (0, 1))
);
-- ##
create table "promotion_products" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "promotion_id" text not null references "promotions" (id) deferrable initially deferred,
  "product_id" text references "products" (id) deferrable initially deferred,
  "category_id" text references "categories" (id) deferrable initially deferred
);
-- ##
create table "stock_movements" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "branch_id" text not null references "branches" (id) deferrable initially deferred,
  "product_id" text not null references "products" (id) deferrable initially deferred,
  "batch_id" text,
  "type" text not null check ("type" is null or "type" in ('opening', 'purchase', 'sale', 'sale_return', 'void', 'supplier_return', 'adjustment', 'damaged', 'expired', 'loss', 'transfer_out', 'transfer_in', 'count_correction')),
  "qty_milli" integer not null check ("qty_milli" is null or typeof("qty_milli") = 'integer'),
  "unit_cost_minor" integer check ("unit_cost_minor" is null or typeof("unit_cost_minor") = 'integer'),
  "cost_currency" text,
  "ref_type" text,
  "ref_id" text,
  "reason" text,
  check (qty_milli <> 0),
  check ((type in ('opening', 'purchase', 'sale_return', 'void', 'transfer_in') and qty_milli > 0) or (type in ('sale', 'supplier_return', 'damaged', 'expired', 'loss', 'transfer_out') and qty_milli < 0) or type in ('adjustment', 'count_correction'))
);
-- ##
create index "stock_movements_ix1" on "stock_movements" ("product_id", "branch_id", "created_at");
-- ##
create index "stock_movements_ix2" on "stock_movements" ("ref_type", "ref_id");
-- ##
create table "stock_batches" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "product_id" text not null references "products" (id) deferrable initially deferred,
  "branch_id" text not null references "branches" (id) deferrable initially deferred,
  "batch_code" text,
  "expiry_date" text,
  "received_at" integer check ("received_at" is null or typeof("received_at") = 'integer')
);
-- ##
create table "stock_takes" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "branch_id" text not null references "branches" (id) deferrable initially deferred,
  "scope" text,
  "status" text check ("status" is null or "status" in ('open', 'counted', 'approved')),
  "started_at" integer check ("started_at" is null or typeof("started_at") = 'integer'),
  "closed_at" integer check ("closed_at" is null or typeof("closed_at") = 'integer'),
  "approved_by" text
);
-- ##
create table "stock_take_lines" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "stock_take_id" text not null references "stock_takes" (id) deferrable initially deferred,
  "product_id" text not null references "products" (id) deferrable initially deferred,
  "batch_id" text,
  "expected_qty_milli" integer not null check ("expected_qty_milli" is null or typeof("expected_qty_milli") = 'integer'),
  "counted_qty_milli" integer check ("counted_qty_milli" is null or typeof("counted_qty_milli") = 'integer')
);
-- ##
create table "stock_transfers" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "from_branch_id" text not null references "branches" (id) deferrable initially deferred,
  "to_branch_id" text not null references "branches" (id) deferrable initially deferred,
  "status" text check ("status" is null or "status" in ('sent', 'received', 'cancelled')),
  "sent_at" integer check ("sent_at" is null or typeof("sent_at") = 'integer'),
  "received_at" integer check ("received_at" is null or typeof("received_at") = 'integer')
);
-- ##
create table "stock_transfer_lines" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "transfer_id" text not null references "stock_transfers" (id) deferrable initially deferred,
  "product_id" text not null references "products" (id) deferrable initially deferred,
  "batch_id" text,
  "qty_milli" integer not null check ("qty_milli" is null or typeof("qty_milli") = 'integer')
);
-- ##
create table "currencies" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "code" text not null,
  "name" text not null,
  "symbol" text,
  "minor_units" integer not null check ("minor_units" is null or typeof("minor_units") = 'integer'),
  "rounding_increment_minor" integer check ("rounding_increment_minor" is null or typeof("rounding_increment_minor") = 'integer'),
  "is_active" integer check ("is_active" is null or "is_active" in (0, 1))
);
-- ##
create table "exchange_rates" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "from_currency" text not null,
  "to_currency" text not null,
  "rate_micro" integer not null check ("rate_micro" is null or typeof("rate_micro") = 'integer'),
  "set_by" text,
  "effective_from" integer not null check ("effective_from" is null or typeof("effective_from") = 'integer'),
  check (rate_micro > 0)
);
-- ##
create index "exchange_rates_ix1" on "exchange_rates" ("from_currency", "to_currency", "effective_from");
-- ##
create table "payment_methods" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "code" text not null,
  "name" text not null,
  "kind" text,
  "currency_scope" text,
  "requires_reference" integer check ("requires_reference" is null or "requires_reference" in (0, 1)),
  "opens_drawer" integer check ("opens_drawer" is null or "opens_drawer" in (0, 1)),
  "is_active" integer check ("is_active" is null or "is_active" in (0, 1))
);
-- ##
create table "shifts" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "branch_id" text not null references "branches" (id) deferrable initially deferred,
  "user_id" text,
  "opened_at" integer not null check ("opened_at" is null or typeof("opened_at") = 'integer'),
  "closed_at" integer check ("closed_at" is null or typeof("closed_at") = 'integer'),
  "status" text check ("status" is null or "status" in ('open', 'closed'))
);
-- ##
create table "shift_cash" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "shift_id" text not null references "shifts" (id) deferrable initially deferred,
  "currency" text not null,
  "opening_float_minor" integer check ("opening_float_minor" is null or typeof("opening_float_minor") = 'integer'),
  "expected_minor" integer check ("expected_minor" is null or typeof("expected_minor") = 'integer'),
  "counted_minor" integer check ("counted_minor" is null or typeof("counted_minor") = 'integer'),
  "difference_minor" integer check ("difference_minor" is null or typeof("difference_minor") = 'integer')
);
-- ##
create table "cash_events" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "shift_id" text not null references "shifts" (id) deferrable initially deferred,
  "currency" text not null,
  "type" text not null check ("type" is null or "type" in ('cash_in', 'cash_out', 'bank_drop')),
  "amount_minor" integer not null check ("amount_minor" is null or typeof("amount_minor") = 'integer'),
  "reason" text,
  check (amount_minor <> 0)
);
-- ##
create table "sales" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "branch_id" text not null references "branches" (id) deferrable initially deferred,
  "shift_id" text references "shifts" (id) deferrable initially deferred,
  "user_id" text,
  "customer_id" text references "customers" (id) deferrable initially deferred,
  "price_tier_id" text,
  "receipt_no" text not null,
  "status" text not null check ("status" is null or "status" in ('completed', 'on_credit', 'layby', 'voided')),
  "sale_currency" text not null,
  "subtotal_minor" integer not null check ("subtotal_minor" is null or typeof("subtotal_minor") = 'integer'),
  "discount_minor" integer not null check ("discount_minor" is null or typeof("discount_minor") = 'integer'),
  "tax_minor" integer not null check ("tax_minor" is null or typeof("tax_minor") = 'integer'),
  "total_minor" integer not null check ("total_minor" is null or typeof("total_minor") = 'integer'),
  "rates_used" text,
  "note" text,
  "completed_at" integer not null check ("completed_at" is null or typeof("completed_at") = 'integer')
);
-- ##
create unique index "sales_ix1" on "sales" ("shop_id", "receipt_no");
-- ##
create index "sales_ix2" on "sales" ("completed_at");
-- ##
create index "sales_ix3" on "sales" ("customer_id");
-- ##
create table "sale_lines" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "sale_id" text not null references "sales" (id) deferrable initially deferred,
  "product_id" text references "products" (id) deferrable initially deferred,
  "batch_id" text,
  "description" text,
  "unit_id" text,
  "qty_milli" integer not null check ("qty_milli" is null or typeof("qty_milli") = 'integer'),
  "unit_price_minor" integer not null check ("unit_price_minor" is null or typeof("unit_price_minor") = 'integer'),
  "price_currency" text,
  "discount_minor" integer check ("discount_minor" is null or typeof("discount_minor") = 'integer'),
  "tax_rate_bp" integer check ("tax_rate_bp" is null or typeof("tax_rate_bp") = 'integer'),
  "tax_minor" integer check ("tax_minor" is null or typeof("tax_minor") = 'integer'),
  "line_total_minor" integer not null check ("line_total_minor" is null or typeof("line_total_minor") = 'integer'),
  "unit_cost_minor" integer check ("unit_cost_minor" is null or typeof("unit_cost_minor") = 'integer'),
  "promotion_id" text
);
-- ##
create index "sale_lines_ix1" on "sale_lines" ("sale_id");
-- ##
create index "sale_lines_ix2" on "sale_lines" ("product_id");
-- ##
create table "sale_payments" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "sale_id" text not null references "sales" (id) deferrable initially deferred,
  "method_code" text not null,
  "currency" text not null,
  "amount_minor" integer not null check ("amount_minor" is null or typeof("amount_minor") = 'integer'),
  "rate_to_sale_micro" integer check ("rate_to_sale_micro" is null or typeof("rate_to_sale_micro") = 'integer'),
  "reference" text,
  "is_change" integer check ("is_change" is null or "is_change" in (0, 1)),
  check (amount_minor <> 0)
);
-- ##
create index "sale_payments_ix1" on "sale_payments" ("sale_id");
-- ##
create table "sale_returns" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "original_sale_id" text not null references "sales" (id) deferrable initially deferred,
  "receipt_no" text not null,
  "kind" text not null check ("kind" is null or "kind" in ('return', 'void')),
  "shift_id" text references "shifts" (id) deferrable initially deferred,
  "reason" text,
  "refund_method" text,
  "refund_currency" text,
  "refund_minor" integer check ("refund_minor" is null or typeof("refund_minor") = 'integer'),
  "approved_by" text
);
-- ##
create unique index "sale_returns_ix1" on "sale_returns" ("shop_id", "receipt_no");
-- ##
create index "sale_returns_ix2" on "sale_returns" ("original_sale_id");
-- ##
create table "return_payouts" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "return_id" text not null references "sale_returns" (id) deferrable initially deferred,
  "method_code" text not null,
  "currency" text not null,
  "amount_minor" integer not null check ("amount_minor" is null or typeof("amount_minor") = 'integer'),
  "rate_to_sale_micro" integer check ("rate_to_sale_micro" is null or typeof("rate_to_sale_micro") = 'integer'),
  "reference" text,
  check (amount_minor > 0)
);
-- ##
create index "return_payouts_ix1" on "return_payouts" ("return_id");
-- ##
create table "sale_return_lines" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "return_id" text not null references "sale_returns" (id) deferrable initially deferred,
  "sale_line_id" text not null references "sale_lines" (id) deferrable initially deferred,
  "qty_milli" integer not null check ("qty_milli" is null or typeof("qty_milli") = 'integer'),
  "restock" integer check ("restock" is null or "restock" in (0, 1)),
  "amount_minor" integer check ("amount_minor" is null or typeof("amount_minor") = 'integer')
);
-- ##
create table "sale_voids" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "sale_id" text not null references "sales" (id) deferrable initially deferred,
  "reason" text,
  "approved_by" text,
  "voided_at" integer not null check ("voided_at" is null or typeof("voided_at") = 'integer')
);
-- ##
create table "account_payments" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "customer_id" text not null references "customers" (id) deferrable initially deferred,
  "sale_id" text references "sales" (id) deferrable initially deferred,
  "receipt_no" text not null,
  "method_code" text not null,
  "currency" text not null,
  "amount_minor" integer not null check ("amount_minor" is null or typeof("amount_minor") = 'integer'),
  "target_currency" text not null,
  "rate_to_target_micro" integer check ("rate_to_target_micro" is null or typeof("rate_to_target_micro") = 'integer'),
  "applied_minor" integer not null check ("applied_minor" is null or typeof("applied_minor") = 'integer'),
  "reference" text,
  "user_id" text,
  check (amount_minor > 0),
  check (applied_minor > 0)
);
-- ##
create unique index "account_payments_ix1" on "account_payments" ("shop_id", "receipt_no");
-- ##
create index "account_payments_ix2" on "account_payments" ("customer_id");
-- ##
create index "account_payments_ix3" on "account_payments" ("sale_id");
-- ##
create table "layby_payments" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "sale_id" text not null references "sales" (id) deferrable initially deferred,
  "payment_id" text,
  "due_note" text
);
-- ##
create table "customers" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "phone" text,
  "address" text,
  "tax_number" text,
  "price_tier_id" text,
  "credit_limit_minor" integer check ("credit_limit_minor" is null or typeof("credit_limit_minor") = 'integer'),
  "credit_currency" text,
  "is_active" integer check ("is_active" is null or "is_active" in (0, 1))
);
-- ##
create index "customers_ix1" on "customers" ("name");
-- ##
create index "customers_ix2" on "customers" ("phone");
-- ##
create table "customer_ledger" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "customer_id" text not null references "customers" (id) deferrable initially deferred,
  "type" text not null check ("type" is null or "type" in ('credit_sale', 'payment', 'refund_credit', 'store_credit_used', 'adjustment')),
  "currency" text not null,
  "amount_minor" integer not null check ("amount_minor" is null or typeof("amount_minor") = 'integer'),
  "ref_type" text,
  "ref_id" text
);
-- ##
create index "customer_ledger_ix1" on "customer_ledger" ("customer_id", "currency");
-- ##
create table "loyalty_ledger" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "customer_id" text not null references "customers" (id) deferrable initially deferred,
  "points" integer not null check ("points" is null or typeof("points") = 'integer'),
  "ref_type" text,
  "ref_id" text,
  "reason" text
);
-- ##
create index "loyalty_ledger_ix1" on "loyalty_ledger" ("customer_id");
-- ##
create table "suppliers" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "phone" text,
  "address" text,
  "terms" text,
  "is_active" integer check ("is_active" is null or "is_active" in (0, 1))
);
-- ##
create table "supplier_products" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "supplier_id" text not null references "suppliers" (id) deferrable initially deferred,
  "product_id" text not null references "products" (id) deferrable initially deferred,
  "supplier_code" text,
  "last_cost_minor" integer check ("last_cost_minor" is null or typeof("last_cost_minor") = 'integer'),
  "cost_currency" text
);
-- ##
create table "purchase_orders" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "supplier_id" text not null references "suppliers" (id) deferrable initially deferred,
  "branch_id" text references "branches" (id) deferrable initially deferred,
  "order_no" text,
  "status" text check ("status" is null or "status" in ('draft', 'sent', 'partly_received', 'received', 'cancelled')),
  "currency" text,
  "ordered_at" integer check ("ordered_at" is null or typeof("ordered_at") = 'integer'),
  "expected_at" integer check ("expected_at" is null or typeof("expected_at") = 'integer')
);
-- ##
create table "purchase_order_lines" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "purchase_order_id" text not null references "purchase_orders" (id) deferrable initially deferred,
  "product_id" text not null references "products" (id) deferrable initially deferred,
  "unit_id" text,
  "qty_milli" integer not null check ("qty_milli" is null or typeof("qty_milli") = 'integer'),
  "cost_minor" integer check ("cost_minor" is null or typeof("cost_minor") = 'integer')
);
-- ##
create table "goods_received" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "supplier_id" text references "suppliers" (id) deferrable initially deferred,
  "branch_id" text not null references "branches" (id) deferrable initially deferred,
  "purchase_order_id" text references "purchase_orders" (id) deferrable initially deferred,
  "receipt_ref" text,
  "currency" text,
  "received_at" integer not null check ("received_at" is null or typeof("received_at") = 'integer')
);
-- ##
create table "goods_received_lines" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "goods_received_id" text not null references "goods_received" (id) deferrable initially deferred,
  "product_id" text not null references "products" (id) deferrable initially deferred,
  "batch_code" text,
  "expiry_date" text,
  "qty_milli" integer not null check ("qty_milli" is null or typeof("qty_milli") = 'integer'),
  "cost_minor" integer check ("cost_minor" is null or typeof("cost_minor") = 'integer')
);
-- ##
create table "supplier_invoices" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "supplier_id" text not null references "suppliers" (id) deferrable initially deferred,
  "goods_received_id" text references "goods_received" (id) deferrable initially deferred,
  "invoice_no" text,
  "currency" text,
  "amount_minor" integer not null check ("amount_minor" is null or typeof("amount_minor") = 'integer'),
  "due_date" text
);
-- ##
create table "supplier_payments" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "supplier_id" text not null references "suppliers" (id) deferrable initially deferred,
  "currency" text not null,
  "amount_minor" integer not null check ("amount_minor" is null or typeof("amount_minor") = 'integer'),
  "method_code" text,
  "reference" text,
  "target_currency" text not null,
  "applied_minor" integer not null check ("applied_minor" is null or typeof("applied_minor") = 'integer'),
  "rate_to_target_micro" integer check ("rate_to_target_micro" is null or typeof("rate_to_target_micro") = 'integer'),
  "user_id" text,
  check (amount_minor > 0),
  check (applied_minor > 0)
);
-- ##
create table "supplier_ledger" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "supplier_id" text not null references "suppliers" (id) deferrable initially deferred,
  "type" text not null,
  "currency" text not null,
  "amount_minor" integer not null check ("amount_minor" is null or typeof("amount_minor") = 'integer'),
  "ref_type" text,
  "ref_id" text
);
-- ##
create index "supplier_ledger_ix1" on "supplier_ledger" ("supplier_id", "currency");
-- ##
create table "expense_categories" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "is_active" integer check ("is_active" is null or "is_active" in (0, 1))
);
-- ##
create table "expenses" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "branch_id" text references "branches" (id) deferrable initially deferred,
  "category_id" text references "expense_categories" (id) deferrable initially deferred,
  "currency" text not null,
  "amount_minor" integer not null check ("amount_minor" is null or typeof("amount_minor") = 'integer'),
  "payee" text,
  "method_code" text,
  "note" text,
  "photo_ref" text,
  "spent_at" integer not null check ("spent_at" is null or typeof("spent_at") = 'integer')
);
-- ##
create table "receipt_templates" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "name" text not null,
  "kind" text not null,
  "paper_width_mm" integer check ("paper_width_mm" is null or typeof("paper_width_mm") = 'integer'),
  "layout" text,
  "is_default" integer check ("is_default" is null or "is_default" in (0, 1))
);
-- ##
create table "settings" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "scope" text not null,
  "scope_id" text,
  "key" text not null,
  "value" text
);
-- ##
create unique index "settings_ix1" on "settings" ("shop_id", "scope", coalesce(scope_id, ''), "key") where deleted_at is null;
-- ##
create table "fiscal_documents" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "sale_id" text references "sales" (id) deferrable initially deferred,
  "kind" text not null,
  "payload" text,
  "status" text check ("status" is null or "status" in ('queued', 'sent', 'failed')),
  "authority_ref" text,
  "sent_at" integer check ("sent_at" is null or typeof("sent_at") = 'integer'),
  "attempts" integer check ("attempts" is null or typeof("attempts") = 'integer')
);
-- ##
create index "fiscal_documents_ix1" on "fiscal_documents" ("status");
-- ##
create table "files" (
  "id" text primary key,
  "shop_id" text not null,
  "created_at" integer not null,
  "created_by" text,
  "device_id" text,
  "updated_at" integer not null,
  "version" integer not null default 1 check (version >= 1),
  "deleted_at" integer,
  "owner_type" text,
  "owner_id" text,
  "kind" text,
  "local_path" text,
  "remote_ref" text,
  "sha256" text,
  "size_bytes" integer check ("size_bytes" is null or typeof("size_bytes") = 'integer'),
  "uploaded_at" integer check ("uploaded_at" is null or typeof("uploaded_at") = 'integer')
);
-- ##
create table held_sales (
  id text primary key, device_id text, user_id text, payload text not null, created_at integer not null
);
-- ##
create table printers (
  id text primary key, device_id text, name text not null, address text not null,
  paper_width_mm integer not null default 58, opens_drawer integer not null default 0 check (opens_drawer in (0, 1))
);
-- ##
create table receipt_counters (
  kind text primary key, last_no integer not null default 0
);
-- ##
create table stock_levels (
  branch_id text not null, product_id text not null, batch_key text not null default '', qty_milli integer not null,
  primary key (branch_id, product_id, batch_key)
) without rowid;
-- ##
create table change_log (
  seq integer primary key autoincrement,
  table_name text not null, row_id text not null,
  op text not null check (op in ('insert', 'update', 'delete')),
  version integer not null, updated_at integer not null, created_at integer not null,
  batch_id text, sent_at integer
);
-- ##
create index change_log_unsent on change_log (sent_at, seq);
-- ##
create table sync_state (
  id integer primary key check (id = 1),
  applying integer not null default 0 check (applying in (0, 1)),
  last_pull_seq integer not null default 0,
  epoch text,
  last_push_at integer, last_success_at integer, last_error text
);
-- ##
create table sync_batches (
  id text primary key, from_seq integer not null, to_seq integer not null,
  status text not null check (status in ('pending', 'sent', 'failed')),
  bytes integer, attempts integer not null default 0, payload text, created_at integer not null
);
-- ##
create table device_state (key text primary key, value text);
-- ##
create trigger "stock_movements_level" after insert on "stock_movements"
begin
  insert into stock_levels (branch_id, product_id, batch_key, qty_milli) values (new.branch_id, new.product_id, coalesce(new.batch_id, ''), new.qty_milli)
  on conflict (branch_id, product_id, batch_key) do update set qty_milli = qty_milli + new.qty_milli;
end;
