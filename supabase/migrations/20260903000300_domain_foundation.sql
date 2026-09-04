-- Phase 3: additive canonical domain foundation.
--
-- These tables coexist with the legacy aggregate tables. No legacy entity is
-- deleted or rewritten here. Canonical rows are materialized only by controlled
-- server-side functions after a legacy user has an unambiguous Auth mapping.

begin;

create extension if not exists pgcrypto;

create table if not exists public.schools (
  id uuid primary key default gen_random_uuid(),
  legacy_user_id text unique,
  name text not null check (btrim(name) <> ''),
  timezone text not null default 'America/Sao_Paulo',
  settings jsonb not null default '{}'::jsonb
    check (jsonb_typeof(settings) = 'object'),
  active boolean not null default true,
  created_by uuid not null references public.profiles(user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

comment on table public.schools is
  'Canonical school tenant. legacy_user_id remains only as migration provenance.';

create table if not exists public.school_memberships (
  school_id uuid not null references public.schools(id) on delete restrict,
  user_id uuid not null references public.profiles(user_id) on delete restrict,
  membership_role text not null check (membership_role in ('owner', 'editor', 'viewer')),
  active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0),
  primary key (school_id, user_id)
);

create index if not exists school_memberships_user_idx
  on public.school_memberships(user_id, school_id)
  where active;

create table if not exists public.school_state_documents (
  school_id uuid primary key references public.schools(id) on delete restrict,
  owner_id uuid not null references public.profiles(user_id) on delete restrict,
  legacy_user_id text,
  data jsonb not null default '{}'::jsonb
    check (jsonb_typeof(data) = 'object'),
  managed_by_legacy boolean not null default true,
  legacy_revision bigint,
  legacy_updated_at timestamptz,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

comment on table public.school_state_documents is
  'Canonical server-side state document during the transition. It preserves a lossless legacy payload plus logical keys.';

create table if not exists public.school_years (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  academic_year integer not null check (academic_year between 2000 and 2200),
  name text not null check (btrim(name) <> ''),
  starts_on date,
  ends_on date,
  status text not null default 'active'
    check (status in ('draft', 'active', 'closed', 'archived')),
  settings jsonb not null default '{}'::jsonb
    check (jsonb_typeof(settings) = 'object'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0),
  constraint school_year_dates_valid check (ends_on is null or starts_on is null or ends_on >= starts_on),
  constraint school_years_school_year_unique unique (school_id, academic_year)
);

comment on table public.school_years is
  'Academic years are tenant-scoped and support a progressive import of legacy 2026 data.';

create table if not exists public.planning_periods (
  id uuid primary key default gen_random_uuid(),
  school_year_id uuid not null references public.school_years(id) on delete restrict,
  sequence_number integer not null check (sequence_number > 0),
  code text not null check (btrim(code) <> ''),
  name text not null check (btrim(name) <> ''),
  starts_on date,
  ends_on date,
  status text not null default 'draft'
    check (status in ('draft', 'active', 'closed', 'archived')),
  settings jsonb not null default '{}'::jsonb
    check (jsonb_typeof(settings) = 'object'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0),
  constraint planning_period_dates_valid check (ends_on is null or starts_on is null or ends_on >= starts_on),
  constraint planning_periods_year_sequence_unique unique (school_year_id, sequence_number),
  constraint planning_periods_year_code_unique unique (school_year_id, code)
);

comment on table public.planning_periods is
  'Configurable planning periods. No assumption is made about four weeks per month or five weeks per cycle.';

create table if not exists public.measurement_units (
  code text primary key check (code = lower(code) and btrim(code) <> ''),
  dimension text not null check (dimension in ('mass', 'volume', 'count', 'package')),
  symbol text not null,
  description text not null,
  active boolean not null default true
);

insert into public.measurement_units (code, dimension, symbol, description)
values
  ('g', 'mass', 'g', 'gram'),
  ('kg', 'mass', 'kg', 'kilogram'),
  ('ml', 'volume', 'mL', 'millilitre'),
  ('l', 'volume', 'L', 'litre'),
  ('unit', 'count', 'un', 'individual unit'),
  ('dozen', 'count', 'dz', 'dozen'),
  ('bunch', 'count', 'maço', 'bunch'),
  ('package', 'package', 'pct', 'package'),
  ('case', 'package', 'cx', 'case')
on conflict (code) do nothing;

create table if not exists public.periodicity_weeks (
  weeks smallint primary key check (weeks between 1 and 53),
  label text not null,
  active boolean not null default true
);

insert into public.periodicity_weeks (weeks, label)
values
  (1, 'weekly'),
  (2, 'every 2 weeks'),
  (3, 'every 3 weeks'),
  (4, 'every 4 weeks'),
  (5, 'every 5 weeks'),
  (6, 'every 6 weeks'),
  (8, 'every 8 weeks'),
  (12, 'every 12 weeks'),
  (13, 'every 13 weeks'),
  (26, 'every 26 weeks'),
  (52, 'every 52 weeks')
on conflict (weeks) do nothing;

create table if not exists public.school_ingredients (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  legacy_name text,
  name text not null check (btrim(name) <> ''),
  base_unit text not null default 'kg' references public.measurement_units(code) on delete restrict,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

create unique index if not exists school_ingredients_name_uidx
  on public.school_ingredients(school_id, lower(name));
create unique index if not exists school_ingredients_legacy_name_uidx
  on public.school_ingredients(school_id, legacy_name)
  where legacy_name is not null;

create table if not exists public.school_ingredient_settings (
  ingredient_id uuid primary key references public.school_ingredients(id) on delete restrict,
  default_purchase_unit text references public.measurement_units(code) on delete restrict,
  default_package_quantity numeric(14,4) check (default_package_quantity is null or default_package_quantity > 0),
  default_package_unit text references public.measurement_units(code) on delete restrict,
  default_unit_sale_quantity numeric(14,4) check (default_unit_sale_quantity is null or default_unit_sale_quantity > 0),
  default_unit_sale_label text,
  reference_price numeric(14,4) check (reference_price is null or reference_price >= 0),
  currency text not null default 'BRL' check (currency ~ '^[A-Z]{3}$'),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

comment on table public.school_ingredient_settings is
  'School-specific packaging, unit-of-sale and price defaults. They are not browser-global values.';

create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  legacy_supplier_id text,
  name text not null check (btrim(name) <> ''),
  tax_id text,
  contact jsonb not null default '{}'::jsonb check (jsonb_typeof(contact) = 'object'),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

create unique index if not exists suppliers_name_uidx
  on public.suppliers(school_id, lower(name));
create unique index if not exists suppliers_legacy_id_uidx
  on public.suppliers(school_id, legacy_supplier_id)
  where legacy_supplier_id is not null;

create table if not exists public.ingredient_suppliers (
  ingredient_id uuid not null references public.school_ingredients(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  active boolean not null default true,
  preferred boolean not null default false,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0),
  primary key (ingredient_id, supplier_id)
);

comment on table public.ingredient_suppliers is
  'Many-to-many supplier eligibility. A supplier is still selected explicitly for each contract or order.';

create table if not exists public.supplier_offers (
  id uuid primary key default gen_random_uuid(),
  ingredient_id uuid not null,
  supplier_id uuid not null,
  planning_period_id uuid references public.planning_periods(id) on delete restrict,
  purchase_unit text not null references public.measurement_units(code) on delete restrict,
  units_per_purchase numeric(14,4) not null default 1 check (units_per_purchase > 0),
  package_quantity numeric(14,4) not null check (package_quantity > 0),
  package_unit text not null references public.measurement_units(code) on delete restrict,
  price numeric(14,4) not null check (price >= 0),
  currency text not null default 'BRL' check (currency ~ '^[A-Z]{3}$'),
  valid_from date,
  valid_until date,
  active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0),
  constraint supplier_offers_ingredient_supplier_fk
    foreign key (ingredient_id, supplier_id)
    references public.ingredient_suppliers(ingredient_id, supplier_id)
    on delete restrict,
  constraint supplier_offer_dates_valid
    check (valid_until is null or valid_from is null or valid_until >= valid_from)
);

create index if not exists supplier_offers_lookup_idx
  on public.supplier_offers(ingredient_id, supplier_id, planning_period_id)
  where active;

create table if not exists public.ingredient_periodicities (
  id uuid primary key default gen_random_uuid(),
  ingredient_id uuid not null references public.school_ingredients(id) on delete restrict,
  planning_period_id uuid not null references public.planning_periods(id) on delete restrict,
  every_weeks smallint not null references public.periodicity_weeks(weeks) on delete restrict,
  anchor_week smallint not null default 1 check (anchor_week between 1 and 53),
  active boolean not null default true,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0),
  constraint ingredient_periodicities_unique unique (ingredient_id, planning_period_id)
);

comment on table public.ingredient_periodicities is
  'Canonical periodicity representation: integer number of weeks only.';

create table if not exists public.procurement_previews (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  planning_period_id uuid references public.planning_periods(id) on delete restrict,
  created_by uuid not null references public.profiles(user_id) on delete restrict,
  legacy_id text,
  name text not null check (btrim(name) <> ''),
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

create unique index if not exists procurement_previews_legacy_uidx
  on public.procurement_previews(school_id, legacy_id)
  where legacy_id is not null;

create table if not exists public.contracts (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  planning_period_id uuid references public.planning_periods(id) on delete restrict,
  legacy_id text,
  contract_number text not null check (btrim(contract_number) <> ''),
  starts_on date,
  ends_on date,
  status text not null default 'active' check (status in ('draft', 'active', 'closed', 'cancelled')),
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_by uuid not null references public.profiles(user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0),
  constraint contract_dates_valid check (ends_on is null or starts_on is null or ends_on >= starts_on),
  constraint contracts_school_number_unique unique (school_id, contract_number)
);

create unique index if not exists contracts_legacy_id_uidx
  on public.contracts(school_id, legacy_id)
  where legacy_id is not null;

create table if not exists public.contract_items (
  id uuid primary key default gen_random_uuid(),
  contract_id uuid not null references public.contracts(id) on delete restrict,
  ingredient_id uuid not null references public.school_ingredients(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  contracted_quantity numeric(14,4) not null check (contracted_quantity >= 0),
  purchase_unit text not null references public.measurement_units(code) on delete restrict,
  winning_price numeric(14,4) not null check (winning_price >= 0),
  preliminary_price numeric(14,4) check (preliminary_price is null or preliminary_price >= 0),
  currency text not null default 'BRL' check (currency ~ '^[A-Z]{3}$'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0),
  constraint contract_items_contract_ingredient_unique unique (contract_id, ingredient_id)
);

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  contract_id uuid references public.contracts(id) on delete restrict,
  planning_period_id uuid references public.planning_periods(id) on delete restrict,
  legacy_id text,
  order_number text,
  status text not null default 'issued' check (status in ('draft', 'issued', 'cancelled', 'received', 'closed')),
  issued_on date,
  metadata jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata) = 'object'),
  created_by uuid not null references public.profiles(user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

create unique index if not exists purchase_orders_legacy_id_uidx
  on public.purchase_orders(school_id, legacy_id)
  where legacy_id is not null;

create table if not exists public.purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete restrict,
  ingredient_id uuid not null references public.school_ingredients(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  contract_item_id uuid references public.contract_items(id) on delete restrict,
  requested_quantity numeric(14,4) not null check (requested_quantity >= 0),
  purchase_unit text not null references public.measurement_units(code) on delete restrict,
  unit_price numeric(14,4) check (unit_price is null or unit_price >= 0),
  currency text not null default 'BRL' check (currency ~ '^[A-Z]{3}$'),
  scheduled_dates jsonb not null default '[]'::jsonb check (jsonb_typeof(scheduled_dates) = 'array'),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0),
  constraint purchase_order_items_order_ingredient_unique unique (purchase_order_id, ingredient_id)
);

create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  ingredient_id uuid not null references public.school_ingredients(id) on delete restrict,
  purchase_order_item_id uuid references public.purchase_order_items(id) on delete restrict,
  movement_type text not null check (movement_type in ('receipt', 'consumption', 'adjustment', 'reversal')),
  quantity numeric(14,4) not null,
  unit text not null references public.measurement_units(code) on delete restrict,
  occurred_on date not null default current_date,
  notes text,
  created_by uuid references public.profiles(user_id) on delete restrict,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

create index if not exists inventory_movements_school_ingredient_date_idx
  on public.inventory_movements(school_id, ingredient_id, occurred_on desc);

-- The global legacy singleton is copied into this queue without assigning it to
-- a school. Assignment is a deliberate administrative step because ownership
-- cannot be inferred safely from fichas_custom.id = 1.
create table if not exists public.technical_sheet_import_queue (
  id uuid primary key default gen_random_uuid(),
  legacy_fichas_custom_id integer not null,
  legacy_owner_id text,
  owner_id uuid references public.profiles(user_id) on delete restrict,
  school_id uuid references public.schools(id) on delete restrict,
  data jsonb not null default '{}'::jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'assigned', 'imported', 'rejected')),
  captured_at timestamptz not null default clock_timestamp(),
  assigned_at timestamptz,
  assigned_by uuid references public.profiles(user_id) on delete restrict,
  notes text,
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0),
  constraint technical_sheet_import_queue_source_unique unique (legacy_fichas_custom_id)
);

create table if not exists public.technical_sheets (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references public.schools(id) on delete restrict,
  owner_id uuid not null references public.profiles(user_id) on delete restrict,
  legacy_fichas_custom_id integer,
  name text not null check (btrim(name) <> ''),
  data jsonb not null default '{}'::jsonb check (jsonb_typeof(data) = 'object'),
  active boolean not null default true,
  imported_from_legacy boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

create unique index if not exists technical_sheets_legacy_source_uidx
  on public.technical_sheets(legacy_fichas_custom_id)
  where legacy_fichas_custom_id is not null;
create index if not exists technical_sheets_school_idx
  on public.technical_sheets(school_id, owner_id)
  where active;

alter table public.schools enable row level security;
alter table public.school_memberships enable row level security;
alter table public.school_state_documents enable row level security;
alter table public.school_years enable row level security;
alter table public.planning_periods enable row level security;
alter table public.measurement_units enable row level security;
alter table public.periodicity_weeks enable row level security;
alter table public.school_ingredients enable row level security;
alter table public.school_ingredient_settings enable row level security;
alter table public.suppliers enable row level security;
alter table public.ingredient_suppliers enable row level security;
alter table public.supplier_offers enable row level security;
alter table public.ingredient_periodicities enable row level security;
alter table public.procurement_previews enable row level security;
alter table public.contracts enable row level security;
alter table public.contract_items enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_items enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.technical_sheet_import_queue enable row level security;
alter table public.technical_sheets enable row level security;

-- Do not revoke the legacy public tables in this additive phase. The final
-- guarded cutover migration handles those grants after the V2 client is live.
do $revoke_new_tables$
declare
  v_table text;
begin
  foreach v_table in array array[
    'schools',
    'school_memberships',
    'school_state_documents',
    'school_years',
    'planning_periods',
    'measurement_units',
    'periodicity_weeks',
    'school_ingredients',
    'school_ingredient_settings',
    'suppliers',
    'ingredient_suppliers',
    'supplier_offers',
    'ingredient_periodicities',
    'procurement_previews',
    'contracts',
    'contract_items',
    'purchase_orders',
    'purchase_order_items',
    'inventory_movements',
    'technical_sheet_import_queue',
    'technical_sheets'
  ]
  loop
    execute format('revoke all on table public.%I from anon, authenticated', v_table);
  end loop;
end
$revoke_new_tables$;

commit;
