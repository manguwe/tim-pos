-- 10-day trials, and a per-phone secret used to reset a forgotten PIN.
alter table licences add column is_trial integer not null default 0 check (is_trial in (0, 1));
alter table activations add column recovery_key text not null default '';
update activations set recovery_key = lower(hex(randomblob(16))) where recovery_key = '';
