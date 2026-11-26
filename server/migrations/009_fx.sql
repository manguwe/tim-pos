-- Live exchange rates, fetched by the server once or twice a day and passed on to phones.
create table fx_rates (
  base text primary key,
  rates text not null,            -- JSON {"ZMW": 27.1, ...}
  source_updated_at integer,      -- when the provider says it last updated
  fetched_at integer not null
);
