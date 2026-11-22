-- Product pictures sent up from the phones. One row per picture, never edited. Small JPEGs (about 30 to 80 KB each).
create table product_photos (
  shop_id text not null references tenants (id),
  name text not null,
  bytes blob not null,
  size integer not null,
  created_at integer not null,
  primary key (shop_id, name)
);
