-- Phase 1: immutable-in-practice, in-database copies of every legacy row.
-- This migration never changes or deletes a source row.

begin;

create schema if not exists app_private;

comment on schema app_private is
  'Server-only application data. Never expose this schema through the Supabase API.';

revoke all on schema app_private from public, anon, authenticated;
alter default privileges in schema app_private revoke all on tables from public, anon, authenticated;
alter default privileges in schema app_private revoke all on sequences from public, anon, authenticated;
alter default privileges in schema app_private revoke execute on functions from public, anon, authenticated;

create table if not exists app_private.legacy_snapshot_manifest (
  snapshot_relation text primary key,
  source_relation text not null,
  captured_at timestamptz not null default clock_timestamp(),
  row_count bigint not null check (row_count >= 0),
  note text not null
);

comment on table app_private.legacy_snapshot_manifest is
  'Manifest for the one-time legacy snapshots captured before any ownership changes.';

do $guard$
begin
  if to_regclass('public.usuarios') is null then
    raise exception 'Required legacy table public.usuarios does not exist';
  end if;
  if to_regclass('public.escola_dados') is null then
    raise exception 'Required legacy table public.escola_dados does not exist';
  end if;
  if to_regclass('public.fichas_custom') is null then
    raise exception 'Required legacy table public.fichas_custom does not exist';
  end if;
end
$guard$;

do $snapshot$
declare
  v_count bigint;
begin
  if to_regclass('app_private.usuarios_snapshot_20260903') is null then
    execute $sql$
      create table app_private.usuarios_snapshot_20260903 as
      select clock_timestamp() as __snapshot_captured_at_20260903, source_row.*
      from public.usuarios as source_row
    $sql$;
  end if;

  execute 'select count(*) from app_private.usuarios_snapshot_20260903' into v_count;
  insert into app_private.legacy_snapshot_manifest
    (snapshot_relation, source_relation, row_count, note)
  values
    ('app_private.usuarios_snapshot_20260903', 'public.usuarios', v_count,
     'Exact additive snapshot; source rows remain in public.usuarios.')
  on conflict (snapshot_relation) do nothing;

  if to_regclass('app_private.escola_dados_snapshot_20260903') is null then
    execute $sql$
      create table app_private.escola_dados_snapshot_20260903 as
      select clock_timestamp() as __snapshot_captured_at_20260903, source_row.*
      from public.escola_dados as source_row
    $sql$;
  end if;

  execute 'select count(*) from app_private.escola_dados_snapshot_20260903' into v_count;
  insert into app_private.legacy_snapshot_manifest
    (snapshot_relation, source_relation, row_count, note)
  values
    ('app_private.escola_dados_snapshot_20260903', 'public.escola_dados', v_count,
     'Exact additive snapshot; source rows remain in public.escola_dados.')
  on conflict (snapshot_relation) do nothing;

  if to_regclass('app_private.fichas_custom_snapshot_20260903') is null then
    execute $sql$
      create table app_private.fichas_custom_snapshot_20260903 as
      select clock_timestamp() as __snapshot_captured_at_20260903, source_row.*
      from public.fichas_custom as source_row
    $sql$;
  end if;

  execute 'select count(*) from app_private.fichas_custom_snapshot_20260903' into v_count;
  insert into app_private.legacy_snapshot_manifest
    (snapshot_relation, source_relation, row_count, note)
  values
    ('app_private.fichas_custom_snapshot_20260903', 'public.fichas_custom', v_count,
     'Exact additive snapshot; source rows remain in public.fichas_custom.')
  on conflict (snapshot_relation) do nothing;
end
$snapshot$;

alter table app_private.legacy_snapshot_manifest enable row level security;
alter table app_private.usuarios_snapshot_20260903 enable row level security;
alter table app_private.escola_dados_snapshot_20260903 enable row level security;
alter table app_private.fichas_custom_snapshot_20260903 enable row level security;

revoke all on all tables in schema app_private from public, anon, authenticated;

comment on table app_private.usuarios_snapshot_20260903 is
  'Pre-migration snapshot of public.usuarios. Do not update or truncate.';
comment on table app_private.escola_dados_snapshot_20260903 is
  'Pre-migration snapshot of public.escola_dados. Do not update or truncate.';
comment on table app_private.fichas_custom_snapshot_20260903 is
  'Pre-migration snapshot of public.fichas_custom. Do not update or truncate.';

commit;
