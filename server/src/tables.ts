/**
 * Which tables a phone may sync, and how each one behaves.
 *
 * append: rows are written once and never change (sales, payments, stock movements, ledgers).
 *         A resend of the same ID is acknowledged and ignored. Updates and deletes are refused.
 * versioned: reference data that can be edited (products, prices, customers, settings).
 *         The higher version wins, ties go to the later updated_at, and a delete is a soft delete.
 */
export type TableKind = 'append' | 'versioned';

const APPEND = [
  'approvals',
  'audit_log',
  'stock_movements',
  'exchange_rates',
  'cash_events',
  'sales',
  'sale_lines',
  'sale_payments',
  'sale_returns',
  'return_payouts',
  'sale_return_lines',
  'sale_voids',
  'layby_payments',
  'account_payments',
  'customer_ledger',
  'loyalty_ledger',
  'goods_received',
  'goods_received_lines',
  'supplier_payments',
  'supplier_ledger',
  'expenses',
];

const VERSIONED = [
  'shops',
  'branches',
  'roles',
  'users',
  'user_branches',
  'categories',
  'units',
  'tax_classes',
  'products',
  'product_units',
  'product_barcodes',
  'bundle_items',
  'price_tiers',
  'product_prices',
  'promotions',
  'promotion_products',
  'stock_batches',
  'stock_takes',
  'stock_take_lines',
  'stock_transfers',
  'stock_transfer_lines',
  'currencies',
  'payment_methods',
  'shifts',
  'shift_cash',
  'customers',
  'suppliers',
  'supplier_products',
  'purchase_orders',
  'purchase_order_lines',
  'supplier_invoices',
  'expense_categories',
  'receipt_templates',
  'settings',
  'fiscal_documents',
  'files',
];

/** Tables that exist only on the phone and are never sent. */
export const LOCAL_ONLY = new Set([
  'held_sales',
  'printers',
  'stock_levels',
  'receipt_counters',
  'change_log',
  'sync_state',
  'sync_batches',
]);

export const TABLES: Record<string, TableKind> = Object.fromEntries([
  ...APPEND.map((t): [string, TableKind] => [t, 'append']),
  ...VERSIONED.map((t): [string, TableKind] => [t, 'versioned']),
]);
