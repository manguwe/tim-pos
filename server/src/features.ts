/**
 * Everything a plan can switch on or off. The phone app checks these names, so a new one needs app code first;
 * which plan has which is edited on the dashboard, never in code.
 */
export interface FeatureInfo { key: string; label: string; description: string }

export const FEATURES: FeatureInfo[] = [
  { key: 'customers', label: 'Customer accounts', description: 'Customer list, credit sales, laybys and what customers owe.' },
  { key: 'purchasing', label: 'Suppliers and buying', description: 'Suppliers, purchase orders, deliveries and what the shop owes.' },
  { key: 'ai', label: 'Team AI', description: 'Online assistant: name from a photo, prices and shop questions, by typing or voice.' },
  { key: 'zimra', label: 'ZIMRA fiscal receipts', description: 'Tax receipts signed for ZIMRA.' },
];

/** Starter plans the vendor can add with one button and then edit. Prices are only a starting point. */
export const SUGGESTED_PLANS = [
  { name: 'Starter', description: 'One phone, selling and stock. For a small tuck shop.', one_time_fee_minor: 0, monthly_fee_minor: 500, currency: 'USD', max_devices: 1, max_branches: 1, max_users: 2, features: [] as string[] },
  { name: 'Business', description: 'More phones and staff, customer accounts and suppliers.', one_time_fee_minor: 0, monthly_fee_minor: 1200, currency: 'USD', max_devices: 3, max_branches: 1, max_users: 6, features: ['customers', 'purchasing'] },
  { name: 'Premium', description: 'Everything, including Team AI and several branches.', one_time_fee_minor: 0, monthly_fee_minor: 2500, currency: 'USD', max_devices: 8, max_branches: 3, max_users: 0, features: ['customers', 'purchasing', 'ai', 'zimra'] },
];
