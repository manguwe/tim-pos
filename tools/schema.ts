/**
 * The phone's database, described once.
 *
 * Column spec:  name[!][>table][{a|b|c}][:i|:s]
 *   !        NOT NULL
 *   >table   foreign key to that table (checked at commit, so rows may arrive in any order)
 *   {a|b}    only these values allowed
 *   :i / :s  force integer / text (otherwise guessed from the name: *_minor, *_milli, *_at, is_* ... are integers)
 *
 * Every synced table also gets the standard columns (see STANDARD_*), which are not repeated below.
 * Money is whole minor units, quantities are thousandths, rates are scaled integers, times are UTC milliseconds.
 */
export interface TableDef {
  cols: string;
  /** extra table-level constraints, raw SQL */
  checks?: string[];
  /** index definitions: columns, optionally prefixed with "unique " and suffixed by " where <sql>" */
  indexes?: string[];
}

export const STANDARD_APPEND = ['id text primary key', 'shop_id text not null', 'created_at integer not null', 'created_by text', 'device_id text'];
export const STANDARD_VERSIONED = [
  ...STANDARD_APPEND,
  'updated_at integer not null',
  'version integer not null default 1 check (version >= 1)',
  'deleted_at integer',
];

const MOVE_PLUS = ['opening', 'purchase', 'sale_return', 'void', 'transfer_in'];
const MOVE_MINUS = ['sale', 'supplier_return', 'damaged', 'expired', 'loss', 'transfer_out'];
const MOVE_EITHER = ['adjustment', 'count_correction'];
const list = (a: string[]) => a.map((x) => `'${x}'`).join(', ');

export const SCHEMA: Record<string, TableDef> = {
  // ---- shop and access ----
  shops: { cols: 'name! country_code! base_currency! tax_registered tax_number settings' },
  branches: { cols: 'name! address phone is_active' },
  roles: { cols: 'name! permissions' },
  users: { cols: 'name! phone email role_id>roles pin_hash password_hash is_active failed_attempts locked_until:i' },
  user_branches: { cols: 'user_id!>users branch_id!>branches', indexes: ['unique shop_id, user_id, branch_id where deleted_at is null'] },
  approvals: { cols: 'action! requested_by approved_by ref_type ref_id' },
  audit_log: { cols: 'user_id action! table_name row_id before after', indexes: ['created_at'] },

  // ---- catalogue and pricing ----
  categories: { cols: 'name! parent_id>categories sort_order' },
  units: { cols: 'name! code! kind{count|weight|volume}' },
  tax_classes: { cols: 'name! rate_bp! is_inclusive' },
  products: {
    cols: 'name! sku category_id>categories brand base_unit_id>units tax_class_id>tax_classes is_active track_stock track_expiry allow_negative_stock parent_product_id>products kind{simple|variant_parent|bundle} cost_minor cost_currency image_ref',
    indexes: ['name', 'sku'],
  },
  product_units: { cols: 'product_id!>products unit_id!>units factor_milli!' },
  product_barcodes: {
    cols: 'product_id!>products unit_id>units barcode!',
    indexes: ['unique shop_id, barcode where deleted_at is null', 'product_id'],
  },
  bundle_items: { cols: 'bundle_product_id!>products component_product_id!>products qty_milli!' },
  price_tiers: { cols: 'name! is_default' },
  product_prices: {
    cols: 'product_id!>products tier_id>price_tiers unit_id>units currency! price_minor! effective_from!:i',
    indexes: ['product_id, tier_id, currency, effective_from'],
  },
  // Quantity prices: from min_qty_milli upwards, each unit costs price_minor (for example 3 or more at 4.00 each).
  price_breaks: {
    cols: 'product_id!>products tier_id>price_tiers currency! min_qty_milli! price_minor!',
    checks: ['check (min_qty_milli > 0)', 'check (price_minor >= 0)'],
    indexes: ['product_id, currency'],
  },
  promotions: { cols: 'name! kind! rules starts_at:i ends_at:i is_active' },
  promotion_products: { cols: 'promotion_id!>promotions product_id>products category_id>categories' },

  // ---- stock ----
  stock_movements: {
    cols: 'branch_id!>branches product_id!>products batch_id type!{opening|purchase|sale|sale_return|void|supplier_return|adjustment|damaged|expired|loss|transfer_out|transfer_in|count_correction} qty_milli! unit_cost_minor cost_currency ref_type ref_id reason',
    checks: [
      `check (qty_milli <> 0)`,
      `check ((type in (${list(MOVE_PLUS)}) and qty_milli > 0) or (type in (${list(MOVE_MINUS)}) and qty_milli < 0) or type in (${list(MOVE_EITHER)}))`,
    ],
    indexes: ['product_id, branch_id, created_at', 'ref_type, ref_id'],
  },
  stock_batches: { cols: 'product_id!>products branch_id!>branches batch_code expiry_date received_at:i' },
  stock_takes: { cols: 'branch_id!>branches scope status{open|counted|approved} started_at:i closed_at:i approved_by' },
  stock_take_lines: { cols: 'stock_take_id!>stock_takes product_id!>products batch_id expected_qty_milli! counted_qty_milli' },
  stock_transfers: { cols: 'from_branch_id!>branches to_branch_id!>branches status{sent|received|cancelled} sent_at:i received_at:i' },
  stock_transfer_lines: { cols: 'transfer_id!>stock_transfers product_id!>products batch_id qty_milli!' },

  // ---- currency, shifts, cash ----
  currencies: { cols: 'code! name! symbol minor_units! rounding_increment_minor is_active' },
  exchange_rates: {
    cols: 'from_currency! to_currency! rate_micro! set_by effective_from!:i',
    checks: ['check (rate_micro > 0)'],
    indexes: ['from_currency, to_currency, effective_from'],
  },
  payment_methods: { cols: 'code! name! kind currency_scope requires_reference opens_drawer is_active:i' },
  shifts: { cols: 'branch_id!>branches user_id opened_at!:i closed_at:i status{open|closed}' },
  shift_cash: { cols: 'shift_id!>shifts currency! opening_float_minor expected_minor counted_minor difference_minor' },
  cash_events: {
    cols: 'shift_id!>shifts currency! type!{cash_in|cash_out|bank_drop} amount_minor! reason',
    checks: ['check (amount_minor <> 0)'],
  },

  // ---- sales ----
  sales: {
    cols: 'branch_id!>branches shift_id>shifts user_id customer_id>customers price_tier_id receipt_no! status!{completed|on_credit|layby|voided} sale_currency! subtotal_minor! discount_minor! tax_minor! total_minor! rates_used note completed_at!:i',
    indexes: ['unique shop_id, receipt_no', 'completed_at', 'customer_id'],
  },
  sale_lines: {
    cols: 'sale_id!>sales product_id>products batch_id description unit_id qty_milli! unit_price_minor! price_currency discount_minor tax_rate_bp tax_minor line_total_minor! unit_cost_minor promotion_id',
    indexes: ['sale_id', 'product_id'],
  },
  sale_payments: {
    cols: 'sale_id!>sales method_code! currency! amount_minor! rate_to_sale_micro reference is_change',
    checks: ['check (amount_minor <> 0)'],
    indexes: ['sale_id'],
  },
  // One row per return or void. refund_minor is the value of the goods in the sale's currency (refund_currency); what was handed back
  // to the customer is in return_payouts, what was taken off their account is in customer_ledger. kind 'void' also gets a sale_voids row.
  sale_returns: { cols: 'original_sale_id!>sales receipt_no! kind!{return|void} shift_id>shifts reason refund_method refund_currency refund_minor approved_by', indexes: ['unique shop_id, receipt_no', 'original_sale_id'] },
  return_payouts: { cols: 'return_id!>sale_returns method_code! currency! amount_minor! rate_to_sale_micro reference', checks: ['check (amount_minor > 0)'], indexes: ['return_id'] },
  sale_return_lines: { cols: 'return_id!>sale_returns sale_line_id!>sale_lines qty_milli! restock amount_minor' },
  sale_voids: { cols: 'sale_id!>sales reason approved_by voided_at!:i' },
  // Money received after the sale: a payment on a customer's account, or an instalment on a layby (sale_id set).
  // applied_minor is how much it reduced the debt, in target_currency (the currency the debt is agreed in).
  account_payments: {
    cols: 'customer_id!>customers sale_id>sales receipt_no! method_code! currency! amount_minor! target_currency! rate_to_target_micro applied_minor! reference user_id',
    checks: ['check (amount_minor > 0)', 'check (applied_minor > 0)'],
    indexes: ['unique shop_id, receipt_no', 'customer_id', 'sale_id'],
  },
  layby_payments: { cols: 'sale_id!>sales payment_id due_note' },

  // ---- customers, suppliers, purchasing ----
  customers: { cols: 'name! phone address tax_number price_tier_id credit_limit_minor credit_currency is_active', indexes: ['name', 'phone'] },
  customer_ledger: {
    cols: 'customer_id!>customers type!{credit_sale|payment|refund_credit|store_credit_used|adjustment} currency! amount_minor! ref_type ref_id',
    indexes: ['customer_id, currency'],
  },
  loyalty_ledger: { cols: 'customer_id!>customers points!:i ref_type ref_id reason', indexes: ['customer_id'] },
  suppliers: { cols: 'name! phone address terms is_active' },
  supplier_products: { cols: 'supplier_id!>suppliers product_id!>products supplier_code last_cost_minor cost_currency' },
  purchase_orders: { cols: 'supplier_id!>suppliers branch_id>branches order_no status{draft|sent|partly_received|received|cancelled} currency ordered_at:i expected_at:i' },
  purchase_order_lines: { cols: 'purchase_order_id!>purchase_orders product_id!>products unit_id qty_milli! cost_minor' },
  goods_received: { cols: 'supplier_id>suppliers branch_id!>branches purchase_order_id>purchase_orders receipt_ref currency received_at!:i' },
  goods_received_lines: { cols: 'goods_received_id!>goods_received product_id!>products batch_code expiry_date qty_milli! cost_minor' },
  supplier_invoices: { cols: 'supplier_id!>suppliers goods_received_id>goods_received invoice_no currency amount_minor! due_date' },
  // currency/amount_minor is what was handed over; target_currency/applied_minor is how much it reduced the debt (the debt stays in its own currency).
  supplier_payments: { cols: 'supplier_id!>suppliers currency! amount_minor! method_code reference target_currency! applied_minor! rate_to_target_micro user_id', checks: ['check (amount_minor > 0)', 'check (applied_minor > 0)'] },
  supplier_ledger: { cols: 'supplier_id!>suppliers type! currency! amount_minor! ref_type ref_id', indexes: ['supplier_id, currency'] },

  // ---- expenses, receipts, settings, fiscal, files ----
  expense_categories: { cols: 'name! is_active' },
  expenses: { cols: 'branch_id>branches category_id>expense_categories currency! amount_minor! payee method_code note photo_ref spent_at!:i' },
  receipt_templates: { cols: 'name! kind! paper_width_mm layout is_default' },
  settings: { cols: 'scope! scope_id key! value', indexes: ["unique shop_id, scope, coalesce(scope_id, ''), key where deleted_at is null"] },
  fiscal_documents: { cols: 'sale_id>sales kind! payload status{queued|sent|failed} authority_ref sent_at:i attempts', indexes: ['status'] },
  files: { cols: 'owner_type owner_id kind local_path remote_ref sha256 size_bytes uploaded_at:i' },
};

/** Tables that exist only on this phone. Raw SQL, not synced, no change log. */
export const LOCAL_SQL: string[] = [
  `create table held_sales (
  id text primary key, device_id text, user_id text, payload text not null, created_at integer not null
)`,
  `create table printers (
  id text primary key, device_id text, name text not null, address text not null,
  paper_width_mm integer not null default 58, opens_drawer integer not null default 0 check (opens_drawer in (0, 1))
)`,
  // One counter per document kind. The prefix (D1, D2 ...) comes from the signed licence, so numbers differ per phone.
  `create table receipt_counters (
  kind text primary key, last_no integer not null default 0
)`,
  // Cache only. Rebuilt from stock_movements at any time. batch_key is '' when a product has no batch.
  `create table stock_levels (
  branch_id text not null, product_id text not null, batch_key text not null default '', qty_milli integer not null,
  primary key (branch_id, product_id, batch_key)
) without rowid`,
  `create table change_log (
  seq integer primary key autoincrement,
  table_name text not null, row_id text not null,
  op text not null check (op in ('insert', 'update', 'delete')),
  version integer not null, updated_at integer not null, created_at integer not null,
  batch_id text, sent_at integer
)`,
  `create index change_log_unsent on change_log (sent_at, seq)`,
  `create table sync_state (
  id integer primary key check (id = 1),
  applying integer not null default 0 check (applying in (0, 1)),
  last_pull_seq integer not null default 0,
  epoch text,
  last_push_at integer, last_success_at integer, last_error text
)`,
  `insert into sync_state (id) values (1)`,
  `create table sync_batches (
  id text primary key, from_seq integer not null, to_seq integer not null,
  status text not null check (status in ('pending', 'sent', 'failed')),
  bytes integer, attempts integer not null default 0, payload text, created_at integer not null
)`,
  // Small key/value store for things that belong to this phone only (device id, licence token copy, last seen time ...).
  `create table device_state (key text primary key, value text)`,
];
