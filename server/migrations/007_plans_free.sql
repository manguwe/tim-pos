-- Free (complimentary) licences, a staff limit, plan descriptions and the vendor's logo for invoices.
alter table licences add column complimentary integer not null default 0 check (complimentary in (0, 1));
-- 0 means no limit on how many people can sign in on a phone.
alter table licences add column max_users integer not null default 0 check (max_users >= 0);
alter table plans add column max_users integer not null default 0 check (max_users >= 0);
alter table plans add column description text not null default '';
alter table billing_profile add column logo text not null default '';

-- Customer accounts and suppliers/buying are now switched by plan. Everything that already exists keeps them.
update licences set features = (select json_group_array(value) from (select value from json_each(licences.features) union select 'customers' union select 'purchasing'));
update plans set features = (select json_group_array(value) from (select value from json_each(plans.features) union select 'customers' union select 'purchasing'));
