-- Every activated phone gets its own receipt prefix (D1, D2, ...), unique within the shop and never reused,
-- so two phones can never print the same receipt number.
alter table activations add column receipt_prefix text;

update activations set receipt_prefix = 'D' || (
  select count(*) from activations a2
  where a2.tenant_id = activations.tenant_id
    and (a2.activated_at < activations.activated_at
      or (a2.activated_at = activations.activated_at and a2.id <= activations.id))
);

create unique index activations_receipt_prefix on activations (tenant_id, receipt_prefix);
