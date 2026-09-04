-- Phase 2: additive identity foundation.
--
-- The three legacy public tables remain authoritative until the explicit
-- cutover migration. This migration only adds ownership columns and private
-- migration records. It never deletes or replaces legacy rows.

begin;

do $guard$
begin
  if to_regnamespace('auth') is null or to_regclass('auth.users') is null then
    raise exception 'Supabase Auth (auth.users) must exist before this migration';
  end if;
  if to_regclass('public.usuarios') is null
     or to_regclass('public.escola_dados') is null
     or to_regclass('public.fichas_custom') is null then
    raise exception 'The legacy usuarios, escola_dados and fichas_custom tables must exist';
  end if;
end
$guard$;

create schema if not exists app_private;
comment on schema app_private is
  'Private migration and authorization records. This schema must never be exposed through PostgREST.';

revoke all on schema app_private from public, anon, authenticated;
alter default privileges in schema app_private revoke all on tables from public, anon, authenticated;
alter default privileges in schema app_private revoke all on sequences from public, anon, authenticated;
alter default privileges in schema app_private revoke execute on functions from public, anon, authenticated;

-- A profile is created only by the controlled migration/admin paths. There is
-- intentionally no auth.users trigger that would grant an OAuth sign-up access.
create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete restrict,
  legacy_user_id text unique,
  login text,
  display_name text not null default '',
  auth_email text,
  google_email text,
  google_subject text,
  status text not null default 'pending'
    check (status in ('pending', 'active', 'disabled')),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

comment on table public.profiles is
  'Canonical application identity keyed by auth.users.id. legacy_user_id is retained only for migration provenance.';

create unique index if not exists profiles_login_ci_uidx
  on public.profiles (lower(login))
  where login is not null;
create unique index if not exists profiles_auth_email_ci_uidx
  on public.profiles (lower(auth_email))
  where auth_email is not null;
create unique index if not exists profiles_google_email_ci_uidx
  on public.profiles (lower(google_email))
  where google_email is not null;
create unique index if not exists profiles_google_subject_uidx
  on public.profiles (google_subject)
  where google_subject is not null;

create table if not exists app_private.legacy_credentials (
  legacy_user_id text primary key check (btrim(legacy_user_id) <> ''),
  legacy_login text,
  legacy_password_sha256 text,
  source_payload jsonb not null,
  copied_at timestamptz not null default clock_timestamp(),
  retired_at timestamptz
);

comment on table app_private.legacy_credentials is
  'Server-only copy of legacy credentials for first-login migration. Never grant this table to browser roles.';

create table if not exists app_private.legacy_user_id_map (
  legacy_user_id text primary key check (btrim(legacy_user_id) <> ''),
  auth_user_id uuid not null unique references auth.users(id) on delete restrict,
  mapped_at timestamptz not null default clock_timestamp(),
  mapped_by uuid references auth.users(id) on delete set null,
  verified_at timestamptz,
  notes text
);

comment on table app_private.legacy_user_id_map is
  'One-to-one bridge from public.usuarios.id to the canonical auth.users UUID.';

create table if not exists app_private.user_authorizations (
  user_id uuid primary key references public.profiles(user_id) on delete restrict,
  app_role text not null check (app_role in ('admin', 'school')),
  active boolean not null default true,
  expires_at timestamptz,
  granted_at timestamptz not null default clock_timestamp(),
  granted_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

comment on table app_private.user_authorizations is
  'Authoritative server-side role, active state and expiry. Browser state is never authoritative.';

-- A Google OAuth identity may exist in auth.users after its first login, but it
-- has no application profile, school membership or data access until an admin
-- approves this request.
create table if not exists app_private.google_access_requests (
  auth_user_id uuid primary key references auth.users(id) on delete restrict,
  google_email text not null,
  google_subject text not null,
  display_name text,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected')),
  requested_at timestamptz not null default clock_timestamp(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  note text,
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

create unique index if not exists google_access_requests_email_ci_uidx
  on app_private.google_access_requests (lower(google_email));
create unique index if not exists google_access_requests_subject_uidx
  on app_private.google_access_requests (google_subject);

-- State is intentionally disabled by default. A later, guarded migration is
-- the only path that marks the Auth/server-first frontend as ready.
create table if not exists app_private.migration_control (
  control_key text primary key,
  enabled boolean not null default false,
  note text,
  updated_at timestamptz not null default clock_timestamp()
);

insert into app_private.migration_control (control_key, enabled, note)
values
  ('server_first_v2', false, 'Enabled only by the final guarded cutover migration'),
  ('legacy_cutover_approved', false, 'Requires backup and migration validation before RLS cutover'),
  ('frontend_v2_verified', false, 'Requires a deployed and tested V2 frontend before RLS cutover')
on conflict (control_key) do nothing;

-- Preserve the legacy identity and add canonical ownership beside it. Existing
-- user_id values and foreign keys are not changed in this migration.
alter table public.usuarios
  add column if not exists revision bigint not null default 1,
  add column if not exists updated_at timestamptz not null default clock_timestamp();

alter table public.escola_dados
  add column if not exists legacy_user_id text,
  add column if not exists owner_id uuid,
  add column if not exists revision bigint not null default 1,
  add column if not exists updated_at timestamptz not null default clock_timestamp();

alter table public.fichas_custom
  add column if not exists legacy_owner_id text,
  add column if not exists owner_id uuid,
  add column if not exists revision bigint not null default 1,
  add column if not exists updated_at timestamptz not null default clock_timestamp();

-- This is provenance only: it copies the current legacy key into a new column.
update public.escola_dados
set legacy_user_id = user_id::text
where legacy_user_id is null;

insert into app_private.legacy_credentials
  (legacy_user_id, legacy_login, legacy_password_sha256, source_payload)
select
  u.id::text,
  nullif(to_jsonb(u) ->> 'login', ''),
  nullif(to_jsonb(u) ->> 'senha_hash', ''),
  to_jsonb(u)
from public.usuarios as u
on conflict (legacy_user_id) do nothing;

do $constraints$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.escola_dados'::regclass
      and conname = 'escola_dados_owner_profile_fk'
  ) then
    alter table public.escola_dados
      add constraint escola_dados_owner_profile_fk
      foreign key (owner_id) references public.profiles(user_id)
      on delete restrict not valid;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.fichas_custom'::regclass
      and conname = 'fichas_custom_owner_profile_fk'
  ) then
    alter table public.fichas_custom
      add constraint fichas_custom_owner_profile_fk
      foreign key (owner_id) references public.profiles(user_id)
      on delete restrict not valid;
  end if;
end
$constraints$;

create index if not exists escola_dados_owner_id_idx
  on public.escola_dados(owner_id);
create index if not exists escola_dados_legacy_user_id_idx
  on public.escola_dados(legacy_user_id);
create index if not exists fichas_custom_owner_id_idx
  on public.fichas_custom(owner_id);
create index if not exists fichas_custom_legacy_owner_id_idx
  on public.fichas_custom(legacy_owner_id);

alter table public.profiles enable row level security;
alter table app_private.legacy_credentials enable row level security;
alter table app_private.legacy_user_id_map enable row level security;
alter table app_private.user_authorizations enable row level security;
alter table app_private.google_access_requests enable row level security;
alter table app_private.migration_control enable row level security;

revoke all on public.profiles from public, anon, authenticated;
revoke all on all tables in schema app_private from public, anon, authenticated;

commit;
