-- Phase 4: server-first migration helpers, optimistic concurrency, session
-- control and recovery records. This remains additive: legacy public tables stay
-- online until the final guarded cutover migration.

begin;

create table if not exists app_private.user_sessions (
  user_id uuid primary key references public.profiles(user_id) on delete restrict,
  auth_session_id uuid not null unique,
  client_label text,
  expires_at timestamptz not null,
  updated_at timestamptz not null default clock_timestamp()
);

create index if not exists user_sessions_user_session_idx
  on app_private.user_sessions(user_id, auth_session_id);

create table if not exists app_private.legacy_browser_state_backup (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references public.profiles(user_id) on delete restrict,
  school_id uuid not null references public.schools(id) on delete restrict,
  source text not null default 'browser-cache',
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  payload_checksum text not null,
  captured_at timestamptz not null default clock_timestamp(),
  captured_by_session_id uuid,
  notes text
);

create table if not exists app_private.legacy_browser_capture_status (
  owner_id uuid primary key references public.profiles(user_id) on delete restrict,
  school_id uuid not null references public.schools(id) on delete restrict,
  status text not null default 'pending'
    check (status in ('pending', 'captured')),
  snapshot_id uuid references app_private.legacy_browser_state_backup(id) on delete restrict,
  captured_at timestamptz,
  updated_at timestamptz not null default clock_timestamp(),
  revision bigint not null default 1 check (revision > 0)
);

alter table app_private.user_sessions enable row level security;
alter table app_private.legacy_browser_state_backup enable row level security;
alter table app_private.legacy_browser_capture_status enable row level security;
revoke all on app_private.user_sessions from public, anon, authenticated;
revoke all on app_private.legacy_browser_state_backup from public, anon, authenticated;
revoke all on app_private.legacy_browser_capture_status from public, anon, authenticated;

-- All revision-managed relations have the same optimistic-concurrency fields.
do $revision_columns$
declare
  v_schema text;
  v_table text;
  v_relation regclass;
begin
  for v_schema, v_table in
    select relation_schema, relation_name
    from (values
      ('public', 'usuarios'),
      ('public', 'escola_dados'),
      ('public', 'fichas_custom'),
      ('public', 'profiles'),
      ('public', 'schools'),
      ('public', 'school_memberships'),
      ('public', 'school_state_documents'),
      ('public', 'school_years'),
      ('public', 'planning_periods'),
      ('public', 'school_ingredients'),
      ('public', 'school_ingredient_settings'),
      ('public', 'suppliers'),
      ('public', 'ingredient_suppliers'),
      ('public', 'supplier_offers'),
      ('public', 'ingredient_periodicities'),
      ('public', 'procurement_previews'),
      ('public', 'contracts'),
      ('public', 'contract_items'),
      ('public', 'purchase_orders'),
      ('public', 'purchase_order_items'),
      ('public', 'inventory_movements'),
      ('public', 'technical_sheet_import_queue'),
      ('public', 'technical_sheets'),
      ('app_private', 'user_authorizations'),
      ('app_private', 'google_access_requests')
    ) as relations(relation_schema, relation_name)
  loop
    v_relation := to_regclass(format('%I.%I', v_schema, v_table));
    if v_relation is not null then
      execute format(
        'alter table %I.%I add column if not exists revision bigint not null default 1',
        v_schema, v_table
      );
      execute format(
        'alter table %I.%I add column if not exists updated_at timestamptz not null default clock_timestamp()',
        v_schema, v_table
      );
    end if;
  end loop;
end
$revision_columns$;

create or replace function app_private.is_service_role()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $function$
  select coalesce(auth.role(), '') = 'service_role'
      or session_user::text in ('postgres', 'supabase_admin')
$function$;

create or replace function app_private.require_service_role()
returns void
language plpgsql
stable
security definer
set search_path = pg_catalog
as $function$
begin
  if not app_private.is_service_role() then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
end
$function$;

create or replace function app_private.current_auth_session_id()
returns uuid
language sql
stable
security definer
set search_path = pg_catalog
as $function$
  select case
    when coalesce(auth.jwt() ->> 'session_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      then (auth.jwt() ->> 'session_id')::uuid
    else null
  end
$function$;

create or replace function app_private.current_auth_expires_at()
returns timestamptz
language sql
stable
security definer
set search_path = pg_catalog
as $function$
  select case
    when coalesce(auth.jwt() ->> 'exp', '') ~ '^[0-9]+$'
      then to_timestamp((auth.jwt() ->> 'exp')::double precision)
    else null
  end
$function$;

create or replace function app_private.profile_payload(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog
as $function$
  select jsonb_build_object(
    'id', p.user_id::text,
    'profile_id', p.user_id::text,
    'auth_user_id', p.user_id::text,
    'data_owner_id', p.user_id::text,
    'legacy_user_id', p.legacy_user_id,
    'login', coalesce(p.login, ''),
    'display_name', p.display_name,
    'role', case a.app_role when 'school' then 'escola' else a.app_role end,
    'active', p.status = 'active'
              and a.active
              and (a.expires_at is null or a.expires_at > clock_timestamp()),
    'expires_at', a.expires_at,
    'google_email', p.google_email,
    'created_at', p.created_at,
    'updated_at', p.updated_at,
    'revision', p.revision,
    'school_id', (
      select m.school_id::text
      from public.school_memberships as m
      join public.schools as s on s.id = m.school_id and s.active
      where m.user_id = p.user_id and m.active
      order by case m.membership_role when 'owner' then 0 when 'editor' then 1 else 2 end, m.created_at
      limit 1
    )
  )
  from public.profiles as p
  join app_private.user_authorizations as a on a.user_id = p.user_id
  where p.user_id = p_user_id
$function$;

create or replace function app_private.user_is_authorized(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $function$
  select exists (
    select 1
    from public.profiles as p
    join app_private.user_authorizations as a on a.user_id = p.user_id
    where p.user_id = p_user_id
      and p.status = 'active'
      and a.active
      and (a.expires_at is null or a.expires_at > clock_timestamp())
  )
$function$;

create or replace function app_private.user_is_admin(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $function$
  select exists (
    select 1
    from public.profiles as p
    join app_private.user_authorizations as a on a.user_id = p.user_id
    where p.user_id = p_user_id
      and p.status = 'active'
      and a.active
      and a.app_role = 'admin'
      and (a.expires_at is null or a.expires_at > clock_timestamp())
  )
$function$;

create or replace function app_private.session_is_current(
  p_user_id uuid,
  p_session_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $function$
  select app_private.user_is_authorized(p_user_id)
     and exists (
       select 1
        from app_private.user_sessions as s
        where s.user_id = p_user_id
          and s.auth_session_id = p_session_id
     )
$function$;

create or replace function app_private.has_active_session()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $function$
  select auth.uid() is not null
     and app_private.current_auth_session_id() is not null
     and app_private.session_is_current(auth.uid(), app_private.current_auth_session_id())
$function$;

create or replace function app_private.current_user_is_admin()
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $function$
  select app_private.has_active_session()
     and app_private.user_is_admin(auth.uid())
$function$;

create or replace function app_private.can_access_school(
  p_school_id uuid,
  p_required_role text default 'viewer'
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog
as $function$
  select app_private.has_active_session()
     and (
       app_private.user_is_admin(auth.uid())
       or exists (
         select 1
         from public.school_memberships as m
         join public.schools as s on s.id = m.school_id and s.active
         where m.school_id = p_school_id
           and m.user_id = auth.uid()
           and m.active
           and case p_required_role
             when 'owner' then m.membership_role = 'owner'
             when 'editor' then m.membership_role in ('owner', 'editor')
             else m.membership_role in ('owner', 'editor', 'viewer')
           end
       )
     )
$function$;

create or replace function app_private.require_active_session()
returns void
language plpgsql
stable
security definer
set search_path = pg_catalog
as $function$
begin
  if not app_private.has_active_session() then
    raise exception using errcode = '42501', message = 'active_session_required';
  end if;
end
$function$;

create or replace function app_private.require_school_editor(p_school_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = pg_catalog
as $function$
begin
  if not app_private.can_access_school(p_school_id, 'editor') then
    raise exception using errcode = '42501', message = 'school_write_not_authorized';
  end if;
end
$function$;

create or replace function app_private.set_updated_at_and_revision()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $function$
begin
  if new is distinct from old then
    new.updated_at := clock_timestamp();
    new.revision := coalesce(old.revision, 0) + 1;
  end if;
  return new;
end
$function$;

do $revision_triggers$
declare
  v_schema text;
  v_table text;
  v_relation regclass;
begin
  for v_schema, v_table in
    select relation_schema, relation_name
    from (values
      ('public', 'usuarios'),
      ('public', 'escola_dados'),
      ('public', 'fichas_custom'),
      ('public', 'profiles'),
      ('public', 'schools'),
      ('public', 'school_memberships'),
      ('public', 'school_state_documents'),
      ('public', 'school_years'),
      ('public', 'planning_periods'),
      ('public', 'school_ingredients'),
      ('public', 'school_ingredient_settings'),
      ('public', 'suppliers'),
      ('public', 'ingredient_suppliers'),
      ('public', 'supplier_offers'),
      ('public', 'ingredient_periodicities'),
      ('public', 'procurement_previews'),
      ('public', 'contracts'),
      ('public', 'contract_items'),
      ('public', 'purchase_orders'),
      ('public', 'purchase_order_items'),
      ('public', 'inventory_movements'),
      ('public', 'technical_sheet_import_queue'),
      ('public', 'technical_sheets'),
      ('app_private', 'user_authorizations'),
      ('app_private', 'google_access_requests')
    ) as relations(relation_schema, relation_name)
  loop
    v_relation := to_regclass(format('%I.%I', v_schema, v_table));
    if v_relation is not null and not exists (
      select 1 from pg_trigger
      where tgrelid = v_relation
        and tgname = 'app_set_updated_at_and_revision'
        and not tgisinternal
    ) then
      execute format(
        'create trigger app_set_updated_at_and_revision before update on %I.%I for each row execute function app_private.set_updated_at_and_revision()',
        v_schema, v_table
      );
    end if;
  end loop;
end
$revision_triggers$;

create or replace function app_private.legacy_config_value(
  p_config jsonb,
  p_key text
)
returns jsonb
language plpgsql
immutable
set search_path = pg_catalog
as $function$
declare
  v_value jsonb;
begin
  v_value := coalesce(p_config, '{}'::jsonb) -> p_key;
  if v_value is null then
    return null;
  end if;
  if jsonb_typeof(v_value) <> 'string' then
    return v_value;
  end if;
  begin
    return (v_value #>> '{}')::jsonb;
  exception when others then
    return v_value;
  end;
end
$function$;

create or replace function app_private.legacy_escola_state(p_row public.escola_dados)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $function$
declare
  v_row jsonb := to_jsonb(p_row);
  v_config jsonb := coalesce(v_row -> 'config', '{}'::jsonb);
begin
  return jsonb_build_object(
    '_legacy_escola_dados', v_row,
    'merenda_niveis', v_row -> 'niveis',
    'merenda_percapta', v_row -> 'percapta',
    'merenda_embalagens', v_row -> 'embalagens',
    'merenda_licitacoes', v_row -> 'licitacoes',
    'merenda_ordens_expedidas', v_row -> 'ordens_expedidas',
    'merenda_recebimentos', v_row -> 'recebimentos',
    'merenda_estoque', v_row -> 'estoque',
    'merenda_semanas_consumidas', v_row -> 'semanas_consumidas',
    'merenda_merc_ajustes', v_row -> 'merc_ajustes',
    'merenda_servidores_config', v_row -> 'servidores_config',
    'merenda_af_custom', v_row -> 'af_custom',
    'merenda_ciclos_planos', v_row -> 'ciclos_planos',
    'merenda_unidades', v_row -> 'unidades',
    'merenda_cal_config', v_row -> 'cal_config',
    'merenda_precos', v_row -> 'precos',
    'merenda_previas_contrato', v_row -> 'previas_contrato',
    'merenda_estoque_correcoes', v_row -> 'estoque_correcoes',
    'merenda_periodicidades', v_row -> 'periodicidades',
    'merenda_ing_periodicidade', v_row -> 'ing_periodicidade',
    'merenda_cardapio', app_private.legacy_config_value(v_config, 'merenda_cardapio'),
    'merenda_header_img', app_private.legacy_config_value(v_config, 'merenda_header_img'),
    'merenda_diretor', app_private.legacy_config_value(v_config, 'merenda_diretor'),
    'merenda_cargo', app_private.legacy_config_value(v_config, 'merenda_cargo'),
    'merenda_escola', app_private.legacy_config_value(v_config, 'merenda_escola'),
    'merenda_subtitulo', app_private.legacy_config_value(v_config, 'merenda_subtitulo'),
    'merenda_fornecedores', app_private.legacy_config_value(v_config, 'merenda_fornecedores'),
    'merenda_ing_fornecedores', app_private.legacy_config_value(v_config, 'merenda_ing_fornecedores')
  );
end
$function$;

create or replace function app_private.materialize_legacy_owner(
  p_legacy_user_id text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_auth_user_id uuid;
  v_profile jsonb;
  v_school_id uuid;
  v_school_year_id uuid;
  v_legacy_row public.escola_dados%rowtype;
  v_state jsonb;
  v_calendar jsonb;
  v_academic_year integer := 2026;
  v_starts_on date;
  v_ends_on date;
  v_sheet_count bigint := 0;
begin
  perform app_private.require_service_role();

  select m.auth_user_id
  into v_auth_user_id
  from app_private.legacy_user_id_map as m
  where m.legacy_user_id = p_legacy_user_id;
  if v_auth_user_id is null then
    raise exception using errcode = '22023', message = 'legacy_mapping_not_found';
  end if;

  update public.escola_dados
  set legacy_user_id = coalesce(legacy_user_id, user_id::text),
      owner_id = v_auth_user_id
  where coalesce(legacy_user_id, user_id::text) = p_legacy_user_id
    and owner_id is distinct from v_auth_user_id;

  select e.*
  into v_legacy_row
  from public.escola_dados as e
  where coalesce(e.legacy_user_id, e.user_id::text) = p_legacy_user_id
  limit 1;

  insert into public.schools (legacy_user_id, name, created_by)
  select
    p_legacy_user_id,
    coalesce(nullif(c.source_payload ->> 'nome', ''), 'Escola ' || p_legacy_user_id),
    v_auth_user_id
  from app_private.legacy_credentials as c
  where c.legacy_user_id = p_legacy_user_id
  on conflict (legacy_user_id) do nothing;

  select s.id into v_school_id
  from public.schools as s
  where s.legacy_user_id = p_legacy_user_id;

  if v_school_id is not null then
    insert into public.school_memberships as membership (school_id, user_id, membership_role)
    values (v_school_id, v_auth_user_id, 'owner')
    on conflict (school_id, user_id) do update
      set membership_role = 'owner', active = true
      where membership.membership_role <> 'owner'
         or not membership.active;

    insert into app_private.legacy_browser_capture_status as capture_status (owner_id, school_id)
    values (v_auth_user_id, v_school_id)
    on conflict (owner_id) do update
      set school_id = excluded.school_id
      where capture_status.status = 'pending';
  end if;

  if v_school_id is not null and v_legacy_row.user_id is not null then
    v_state := app_private.legacy_escola_state(v_legacy_row);
    insert into public.school_state_documents as state_document (
      school_id, owner_id, legacy_user_id, data, managed_by_legacy,
      legacy_revision, legacy_updated_at
    ) values (
      v_school_id,
      v_auth_user_id,
      p_legacy_user_id,
      v_state,
      true,
      v_legacy_row.revision,
      v_legacy_row.updated_at
    )
    on conflict (school_id) do update
      set owner_id = excluded.owner_id,
          legacy_user_id = excluded.legacy_user_id,
          data = state_document.data || excluded.data,
          legacy_revision = excluded.legacy_revision,
          legacy_updated_at = excluded.legacy_updated_at
      where state_document.managed_by_legacy;

    v_calendar := v_state -> 'merenda_cal_config';
    begin
      if coalesce(v_calendar ->> 'inicio', '') ~ '^\d{4}-\d{2}-\d{2}$' then
        v_starts_on := (v_calendar ->> 'inicio')::date;
        v_academic_year := extract(year from v_starts_on)::integer;
      end if;
      if coalesce(v_calendar ->> 'fim', '') ~ '^\d{4}-\d{2}-\d{2}$' then
        v_ends_on := (v_calendar ->> 'fim')::date;
      end if;
    exception when others then
      v_starts_on := null;
      v_ends_on := null;
      v_academic_year := 2026;
    end;
    insert into public.school_years (
      school_id, academic_year, name, starts_on, ends_on, status, settings
    ) values (
      v_school_id,
      v_academic_year,
      'Ano letivo ' || v_academic_year::text,
      v_starts_on,
      v_ends_on,
      'active',
      jsonb_build_object('legacy_import', true)
    )
    on conflict (school_id, academic_year) do nothing;
    select id into v_school_year_id
    from public.school_years
    where school_id = v_school_id and academic_year = v_academic_year;
    if v_school_year_id is not null then
      insert into public.planning_periods (
        school_year_id, sequence_number, code, name, starts_on, ends_on, status, settings
      ) values (
        v_school_year_id,
        1,
        'legacy-annual',
        'Planejamento anual legado',
        v_starts_on,
        v_ends_on,
        'active',
        jsonb_build_object('legacy_import', true)
      )
      on conflict (school_year_id, code) do nothing;
    end if;
  end if;

  insert into public.technical_sheet_import_queue as technical_queue (
    legacy_fichas_custom_id, legacy_owner_id, data, status
  )
  select f.id, f.legacy_owner_id, f.dados, 'pending'
  from public.fichas_custom as f
  on conflict (legacy_fichas_custom_id) do update
    set data = excluded.data
    where technical_queue.status = 'pending';
  get diagnostics v_sheet_count = row_count;

  v_profile := app_private.profile_payload(v_auth_user_id);
  return jsonb_build_object(
    'profile', v_profile,
    'school_id', v_school_id,
    'technical_sheet_imports_captured', v_sheet_count
  );
end
$function$;

create or replace function app_private.mirror_legacy_escola_data()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_school_id uuid;
begin
  if new.owner_id is null then
    return new;
  end if;
  select s.id into v_school_id
  from public.schools as s
  where s.legacy_user_id = coalesce(new.legacy_user_id, new.user_id::text);
  if v_school_id is null then
    return new;
  end if;
  insert into public.school_state_documents as state_document (
    school_id, owner_id, legacy_user_id, data, managed_by_legacy,
    legacy_revision, legacy_updated_at
  ) values (
    v_school_id,
    new.owner_id,
    coalesce(new.legacy_user_id, new.user_id::text),
    app_private.legacy_escola_state(new),
    true,
    new.revision,
    new.updated_at
  )
  on conflict (school_id) do update
    set owner_id = excluded.owner_id,
        legacy_user_id = excluded.legacy_user_id,
        data = state_document.data || excluded.data,
        legacy_revision = excluded.legacy_revision,
        legacy_updated_at = excluded.legacy_updated_at
    where state_document.managed_by_legacy;
  return new;
end
$function$;

do $legacy_mirror_trigger$
begin
  if not exists (
    select 1 from pg_trigger
    where tgrelid = 'public.escola_dados'::regclass
      and tgname = 'app_mirror_legacy_escola_data'
      and not tgisinternal
  ) then
    create trigger app_mirror_legacy_escola_data
      after insert or update on public.escola_dados
      for each row execute function app_private.mirror_legacy_escola_data();
  end if;
end
$legacy_mirror_trigger$;

-- Edge Function contracts. These functions are service-role only because they
-- handle private migration records and are called after server-side token
-- verification in the Edge runtime.
create or replace function public.edge_legacy_login_verify(
  p_username text,
  p_password_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_credential app_private.legacy_credentials%rowtype;
  v_auth_user_id uuid;
  v_expiry date;
  v_active boolean;
  v_matches bigint;
begin
  perform app_private.require_service_role();
  select count(*) into v_matches
  from app_private.legacy_credentials as c
  where lower(c.legacy_login) = lower(btrim(p_username))
    and c.legacy_password_sha256 = p_password_sha256;
  if v_matches <> 1 then
    return null;
  end if;
  select c.* into v_credential
  from app_private.legacy_credentials as c
  where lower(c.legacy_login) = lower(btrim(p_username))
    and c.legacy_password_sha256 = p_password_sha256;
  if not found then
    return null;
  end if;
  v_active := case lower(coalesce(v_credential.source_payload ->> 'ativo', 'true'))
    when 'false' then false
    when '0' then false
    else true
  end;
  if not v_active then
    return null;
  end if;
  begin
    v_expiry := nullif(v_credential.source_payload ->> 'data_expiracao', '')::date;
  exception when others then
    return null;
  end;
  if v_expiry is not null and v_expiry < current_date then
    return null;
  end if;
  select m.auth_user_id into v_auth_user_id
  from app_private.legacy_user_id_map as m
  where m.legacy_user_id = v_credential.legacy_user_id;
  return jsonb_build_object(
    'legacy_id', v_credential.legacy_user_id,
    'auth_user_id', v_auth_user_id
  );
end
$function$;

create or replace function public.edge_login_resolve(p_username text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_auth_user_id uuid;
begin
  perform app_private.require_service_role();
  select p.user_id into v_auth_user_id
  from public.profiles as p
  join app_private.user_authorizations as a on a.user_id = p.user_id
  where lower(p.login) = lower(btrim(p_username))
    and p.status = 'active'
    and a.active
    and (a.expires_at is null or a.expires_at > clock_timestamp());
  if v_auth_user_id is null then
    return null;
  end if;
  return app_private.profile_payload(v_auth_user_id);
end
$function$;

create or replace function public.edge_legacy_login_complete(
  p_legacy_id text,
  p_auth_user_id uuid,
  p_auth_email text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_credential app_private.legacy_credentials%rowtype;
  v_existing_auth uuid;
  v_existing_legacy text;
  v_profile_legacy text;
  v_role text;
  v_active boolean;
  v_expires_at timestamptz;
  v_materialized jsonb;
begin
  perform app_private.require_service_role();
  select c.* into v_credential
  from app_private.legacy_credentials as c
  where c.legacy_user_id = p_legacy_id
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'legacy_user_not_found';
  end if;
  if not exists (select 1 from auth.users where id = p_auth_user_id) then
    raise exception using errcode = '22023', message = 'auth_user_not_found';
  end if;
  select auth_user_id into v_existing_auth
  from app_private.legacy_user_id_map
  where legacy_user_id = p_legacy_id;
  if v_existing_auth is not null and v_existing_auth <> p_auth_user_id then
    raise exception using errcode = '23505', message = 'legacy_user_already_mapped';
  end if;
  select legacy_user_id into v_existing_legacy
  from app_private.legacy_user_id_map
  where auth_user_id = p_auth_user_id;
  if v_existing_legacy is not null and v_existing_legacy <> p_legacy_id then
    raise exception using errcode = '23505', message = 'auth_user_already_mapped';
  end if;
  select legacy_user_id into v_profile_legacy
  from public.profiles
  where user_id = p_auth_user_id
  for update;
  if v_profile_legacy is not null and v_profile_legacy <> p_legacy_id then
    raise exception using errcode = '23505', message = 'auth_profile_already_bound_to_other_legacy_user';
  end if;

  v_role := case lower(coalesce(v_credential.source_payload ->> 'role', 'escola'))
    when 'admin' then 'admin'
    when 'administrator' then 'admin'
    else 'school'
  end;
  v_active := case lower(coalesce(v_credential.source_payload ->> 'ativo', 'true'))
    when 'false' then false
    when '0' then false
    else true
  end;
  begin
    v_expires_at := nullif(v_credential.source_payload ->> 'data_expiracao', '')::date::timestamptz + interval '1 day';
  exception when others then
    v_expires_at := null;
  end;

  insert into public.profiles (
    user_id, legacy_user_id, login, display_name, auth_email, status
  ) values (
    p_auth_user_id,
    p_legacy_id,
    v_credential.legacy_login,
    coalesce(nullif(v_credential.source_payload ->> 'nome', ''), v_credential.legacy_login, 'User'),
    nullif(lower(btrim(p_auth_email)), ''),
    case when v_active then 'active' else 'disabled' end
  )
  on conflict (user_id) do update
    set legacy_user_id = excluded.legacy_user_id,
        login = coalesce(nullif(login, ''), excluded.login),
        display_name = coalesce(nullif(display_name, ''), excluded.display_name),
        auth_email = coalesce(auth_email, excluded.auth_email),
        status = case when status = 'disabled' then 'disabled' else excluded.status end;

  insert into app_private.legacy_user_id_map (
    legacy_user_id, auth_user_id, verified_at
  ) values (
    p_legacy_id, p_auth_user_id, clock_timestamp()
  )
  on conflict (legacy_user_id) do update
    set verified_at = excluded.verified_at;

  insert into app_private.user_authorizations (
    user_id, app_role, active, expires_at
  ) values (
    p_auth_user_id, v_role, v_active, v_expires_at
  )
  on conflict (user_id) do update
    set app_role = excluded.app_role,
        active = excluded.active,
        expires_at = excluded.expires_at;

  v_materialized := app_private.materialize_legacy_owner(p_legacy_id);
  return coalesce(v_materialized -> 'profile', app_private.profile_payload(p_auth_user_id));
end
$function$;

create or replace function public.edge_session_activate(
  p_auth_user_id uuid,
  p_session_id uuid,
  p_expires_at timestamptz,
  p_client_label text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
begin
  perform app_private.require_service_role();
  if not app_private.user_is_authorized(p_auth_user_id) then
    return jsonb_build_object('allowed', false, 'active', false, 'newest', false, 'reason', 'profile_inactive', 'profile', null);
  end if;
  if p_expires_at <= clock_timestamp() then
    return jsonb_build_object('allowed', false, 'active', false, 'newest', false, 'reason', 'jwt_expired', 'profile', null);
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_auth_user_id::text, 0));
  -- One row per user: replacing it invalidates the old session without
  -- retaining prior session rows.
  insert into app_private.user_sessions (
    user_id, auth_session_id, client_label, expires_at
  ) values (
    p_auth_user_id, p_session_id, nullif(p_client_label, ''), p_expires_at
  )
  on conflict (user_id) do update
    set auth_session_id = excluded.auth_session_id,
        client_label = excluded.client_label,
        expires_at = excluded.expires_at,
        updated_at = clock_timestamp();
  return jsonb_build_object(
    'allowed', true,
    'active', true,
    'newest', true,
    'reason', null,
    'profile', app_private.profile_payload(p_auth_user_id)
  );
end
$function$;

create or replace function public.edge_session_authorize(
  p_auth_user_id uuid,
  p_auth_session_id uuid,
  p_required_role text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_profile jsonb;
  v_active boolean;
  v_newest boolean;
  v_role text;
begin
  perform app_private.require_service_role();
  v_profile := app_private.profile_payload(p_auth_user_id);
  if v_profile is null then
    return jsonb_build_object('allowed', false, 'active', false, 'newest', false, 'reason', 'profile_missing', 'profile', null);
  end if;
  v_active := coalesce((v_profile ->> 'active')::boolean, false);
  v_role := v_profile ->> 'role';
  v_newest := app_private.session_is_current(p_auth_user_id, p_auth_session_id);
  if not v_active then
    return jsonb_build_object('allowed', false, 'active', false, 'newest', v_newest, 'reason', 'profile_inactive', 'profile', v_profile);
  end if;
  if not v_newest then
    return jsonb_build_object('allowed', false, 'active', true, 'newest', false, 'reason', 'session_replaced', 'profile', v_profile);
  end if;
  if p_required_role is not null and p_required_role <> '' and v_role <> p_required_role then
    return jsonb_build_object('allowed', false, 'active', true, 'newest', true, 'reason', 'role', 'profile', v_profile);
  end if;
  return jsonb_build_object('allowed', true, 'active', true, 'newest', true, 'reason', null, 'profile', v_profile);
end
$function$;

create or replace function public.edge_session_revoke(
  p_auth_user_id uuid,
  p_auth_session_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $function$
begin
  perform app_private.require_service_role();
  delete from app_private.user_sessions
  where user_id = p_auth_user_id
    and auth_session_id = p_auth_session_id;
  return found;
end
$function$;

create or replace function public.edge_claim_google_login(
  p_auth_user_id uuid,
  p_google_subject text,
  p_google_email text,
  p_display_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_profile jsonb;
begin
  perform app_private.require_service_role();
  select app_private.profile_payload(p.user_id)
  into v_profile
  from public.profiles as p
  join app_private.user_authorizations as a on a.user_id = p.user_id
  where p.user_id = p_auth_user_id
    and p.status = 'active'
    and a.active
    and (a.expires_at is null or a.expires_at > clock_timestamp())
    and lower(p.google_email) = lower(btrim(p_google_email))
    and (p.google_subject is null or p.google_subject = p_google_subject);
  if v_profile is not null then
    update public.profiles
    set google_subject = coalesce(google_subject, p_google_subject)
    where user_id = p_auth_user_id;
    update app_private.google_access_requests
    set status = 'approved', reviewed_at = coalesce(reviewed_at, clock_timestamp())
    where auth_user_id = p_auth_user_id and status = 'pending';
    return jsonb_build_object('status', 'approved', 'profile', app_private.profile_payload(p_auth_user_id));
  end if;

  if exists (
    select 1 from app_private.google_access_requests
    where auth_user_id <> p_auth_user_id
      and (lower(google_email) = lower(btrim(p_google_email)) or google_subject = p_google_subject)
      and status in ('pending', 'approved')
  ) then
    return jsonb_build_object('status', 'rejected', 'reason', 'identity_already_registered');
  end if;
  insert into app_private.google_access_requests as request_row (
    auth_user_id, google_email, google_subject, display_name, status
  ) values (
    p_auth_user_id,
    lower(btrim(p_google_email)),
    btrim(p_google_subject),
    nullif(btrim(p_display_name), ''),
    'pending'
  )
  on conflict (auth_user_id) do update
    set google_email = excluded.google_email,
        google_subject = excluded.google_subject,
        display_name = coalesce(excluded.display_name, request_row.display_name),
        requested_at = clock_timestamp()
    where request_row.status = 'pending';
  return jsonb_build_object('status', 'pending');
end
$function$;

-- Browser RPCs use the authenticated JWT and the active-session gate. No
-- browser role receives direct write permission to functional tables.
create or replace function public.app_v2_capabilities()
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog
as $function$
  select jsonb_build_object(
    'ready', coalesce((select enabled from app_private.migration_control where control_key = 'server_first_v2'), false),
    'reason', case when coalesce((select enabled from app_private.migration_control where control_key = 'server_first_v2'), false)
      then null else 'migration-not-ready' end,
    'migration', 'server-first-v2',
    'api_version', 2,
    'features', jsonb_build_object(
      'supabase_auth', true,
      'profile_validation', true,
      'legacy_login', true,
      'google_oauth_claim', true,
      'school_state', true,
      'revisioned_save', true,
      'admin_users', true,
      'single_session', true
    )
  )
$function$;

create or replace function public.app_v2_session_context()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_profile jsonb;
  v_expires_at timestamptz;
begin
  v_expires_at := app_private.current_auth_expires_at();
  if v_expires_at is null or v_expires_at <= clock_timestamp() or not app_private.has_active_session() then
    return jsonb_build_object('valid', false, 'reason', 'active_session_required', 'profile', null);
  end if;
  update app_private.user_sessions
  set expires_at = v_expires_at,
      updated_at = clock_timestamp()
  where user_id = auth.uid()
    and auth_session_id = app_private.current_auth_session_id();
  v_profile := app_private.profile_payload(auth.uid());
  return jsonb_build_object(
    'valid', true,
    'reason', null,
    'auth_user_id', auth.uid()::text,
    'school_id', v_profile ->> 'school_id',
    'profile', v_profile
  );
end
$function$;

create or replace function public.app_v2_end_session()
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_session_id uuid;
begin
  perform app_private.require_active_session();
  v_session_id := app_private.current_auth_session_id();
  delete from app_private.user_sessions
  where user_id = auth.uid()
    and auth_session_id = v_session_id;
  return found;
end
$function$;

create or replace function public.app_v2_load_school_state()
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_school_id uuid;
  v_document public.school_state_documents%rowtype;
begin
  perform app_private.require_active_session();
  select m.school_id into v_school_id
  from public.school_memberships as m
  where m.user_id = auth.uid() and m.active
  order by case m.membership_role when 'owner' then 0 when 'editor' then 1 else 2 end, m.created_at
  limit 1;
  if v_school_id is null then
    raise exception using errcode = '42501', message = 'school_context_required';
  end if;
  if not app_private.can_access_school(v_school_id, 'viewer') then
    raise exception using errcode = '42501', message = 'school_read_not_authorized';
  end if;
  select d.* into v_document
  from public.school_state_documents as d
  where d.school_id = v_school_id;
  if not found then
    raise exception using errcode = '22023', message = 'school_state_not_materialized';
  end if;
  return jsonb_build_object(
    'ok', true,
    'school_id', v_document.school_id::text,
    'revision', v_document.revision,
    'updated_at', v_document.updated_at,
    'state', v_document.data
  );
end
$function$;

create or replace function public.app_v2_save_school_state(
  p_expected_revision bigint,
  p_state jsonb,
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_school_id uuid;
  v_document public.school_state_documents%rowtype;
begin
  perform app_private.require_active_session();
  if p_expected_revision < 1 then
    raise exception using errcode = '22023', message = 'expected_revision_invalid';
  end if;
  if jsonb_typeof(p_state) <> 'object' then
    raise exception using errcode = '22023', message = 'state_must_be_object';
  end if;
  if octet_length(p_state::text) > 5242880 then
    raise exception using errcode = '22023', message = 'state_payload_too_large';
  end if;
  select m.school_id into v_school_id
  from public.school_memberships as m
  where m.user_id = auth.uid() and m.active
  order by case m.membership_role when 'owner' then 0 when 'editor' then 1 else 2 end, m.created_at
  limit 1;
  if v_school_id is null then
    raise exception using errcode = '42501', message = 'school_context_required';
  end if;
  perform app_private.require_school_editor(v_school_id);

  select d.* into v_document
  from public.school_state_documents as d
  where d.school_id = v_school_id
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'school_state_not_materialized';
  end if;
  if v_document.revision <> p_expected_revision then
    return jsonb_build_object(
      'ok', false,
      'code', 'revision_conflict',
      'current', jsonb_build_object(
        'ok', true,
        'school_id', v_document.school_id::text,
        'revision', v_document.revision,
        'updated_at', v_document.updated_at,
        'state', v_document.data
      )
    );
  end if;

  update public.school_state_documents
  set data = p_state,
      owner_id = auth.uid(),
      managed_by_legacy = false
  where school_id = v_school_id
  returning * into v_document;

  return jsonb_build_object(
    'ok', true,
    'school_id', v_document.school_id::text,
    'revision', v_document.revision,
    'updated_at', v_document.updated_at,
    'state', v_document.data
  );
end
$function$;

create or replace function public.app_v2_capture_legacy_browser_state(
  p_payload jsonb,
  p_source text default 'browser-cache'
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_school_id uuid;
  v_snapshot_id uuid;
  v_document public.school_state_documents%rowtype;
  v_values jsonb;
  v_missing jsonb;
begin
  perform app_private.require_active_session();
  if jsonb_typeof(p_payload) <> 'object' then
    raise exception using errcode = '22023', message = 'legacy_payload_must_be_object';
  end if;
  if octet_length(p_payload::text) > 5242880 then
    raise exception using errcode = '22023', message = 'legacy_payload_too_large';
  end if;
  select m.school_id into v_school_id
  from public.school_memberships as m
  where m.user_id = auth.uid() and m.active
  order by case m.membership_role when 'owner' then 0 when 'editor' then 1 else 2 end, m.created_at
  limit 1;
  if v_school_id is null then
    raise exception using errcode = '42501', message = 'school_context_required';
  end if;
  perform app_private.require_school_editor(v_school_id);
  insert into app_private.legacy_browser_state_backup (
    owner_id, school_id, source, payload, payload_checksum, captured_by_session_id
  ) values (
    auth.uid(),
    v_school_id,
    left(coalesce(nullif(btrim(p_source), ''), 'browser-cache'), 100),
    p_payload,
    md5(p_payload::text),
    app_private.current_auth_session_id()
  )
  on conflict (owner_id) do update
    set school_id = excluded.school_id,
        source = excluded.source,
        payload = excluded.payload,
        payload_checksum = excluded.payload_checksum,
        captured_at = excluded.captured_at,
        captured_by_session_id = excluded.captured_by_session_id
  returning id into v_snapshot_id;

  v_values := case
    when jsonb_typeof(p_payload -> 'values') = 'object' then p_payload -> 'values'
    else p_payload
  end;
  select d.* into v_document
  from public.school_state_documents as d
  where d.school_id = v_school_id
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'school_state_not_materialized';
  end if;
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
  into v_missing
  from jsonb_each(v_values)
  where not (v_document.data ? key);
  if v_missing <> '{}'::jsonb then
    update public.school_state_documents
    set data = data || v_missing
    where school_id = v_school_id;
  end if;
  update app_private.legacy_browser_capture_status
  set status = 'captured',
      snapshot_id = v_snapshot_id,
      captured_at = clock_timestamp()
  where owner_id = auth.uid();
  return jsonb_build_object(
    'ok', true,
    'snapshot_id', v_snapshot_id::text,
    'imported_keys', coalesce((select jsonb_agg(key order by key) from jsonb_object_keys(v_missing) as keys(key)), '[]'::jsonb)
  );
end
$function$;

-- Finalize the migration map for users that an Edge Function has already
-- authenticated. This does not create Auth users and does not infer ownership
-- of the historical global fichas_custom singleton.
create or replace function public.admin_refresh_legacy_ownership(
  p_legacy_user_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_count integer := 0;
  v_legacy_id text;
begin
  perform app_private.require_service_role();
  for v_legacy_id in
    select legacy_user_id
    from app_private.legacy_user_id_map
    where p_legacy_user_id is null or legacy_user_id = p_legacy_user_id
  loop
    perform app_private.materialize_legacy_owner(v_legacy_id);
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('ok', true, 'owners_materialized', v_count);
end
$function$;

-- Policies are installed now for all V2 tables. Direct browser grants remain
-- absent; the server-first RPCs are the supported V2 API.
do $policies$
declare
  v_table text;
begin
  foreach v_table in array array[
    'schools', 'school_memberships', 'school_state_documents', 'school_years',
    'planning_periods', 'school_ingredients', 'school_ingredient_settings',
    'suppliers', 'ingredient_suppliers', 'supplier_offers',
    'ingredient_periodicities', 'procurement_previews', 'contracts',
    'contract_items', 'purchase_orders', 'purchase_order_items',
    'inventory_movements', 'technical_sheet_import_queue', 'technical_sheets'
  ]
  loop
    execute format('drop policy if exists app_v2_read on public.%I', v_table);
    execute format('drop policy if exists app_v2_write on public.%I', v_table);
  end loop;
end
$policies$;

create policy app_v2_profile_read_own
  on public.profiles for select to authenticated
  using (user_id = auth.uid() and app_private.has_active_session());

create policy app_v2_school_read
  on public.schools for select to authenticated
  using (app_private.can_access_school(id, 'viewer'));
create policy app_v2_membership_read
  on public.school_memberships for select to authenticated
  using (app_private.can_access_school(school_id, 'viewer'));
create policy app_v2_document_read
  on public.school_state_documents for select to authenticated
  using (app_private.can_access_school(school_id, 'viewer'));
create policy app_v2_year_read
  on public.school_years for select to authenticated
  using (app_private.can_access_school(school_id, 'viewer'));
create policy app_v2_period_read
  on public.planning_periods for select to authenticated
  using (app_private.can_access_school((select y.school_id from public.school_years y where y.id = school_year_id), 'viewer'));
create policy app_v2_ingredient_read
  on public.school_ingredients for select to authenticated
  using (app_private.can_access_school(school_id, 'viewer'));
create policy app_v2_supplier_read
  on public.suppliers for select to authenticated
  using (app_private.can_access_school(school_id, 'viewer'));
create policy app_v2_preview_read
  on public.procurement_previews for select to authenticated
  using (app_private.can_access_school(school_id, 'viewer'));
create policy app_v2_contract_read
  on public.contracts for select to authenticated
  using (app_private.can_access_school(school_id, 'viewer'));
create policy app_v2_order_read
  on public.purchase_orders for select to authenticated
  using (app_private.can_access_school(school_id, 'viewer'));
create policy app_v2_inventory_read
  on public.inventory_movements for select to authenticated
  using (app_private.can_access_school(school_id, 'viewer'));
create policy app_v2_technical_sheet_read
  on public.technical_sheets for select to authenticated
  using (app_private.can_access_school(school_id, 'viewer'));
revoke all on function app_private.is_service_role() from public, anon, authenticated;
revoke all on function app_private.require_service_role() from public, anon, authenticated;
revoke all on function app_private.current_auth_session_id() from public, anon, authenticated;
revoke all on function app_private.current_auth_expires_at() from public, anon, authenticated;
revoke all on function app_private.profile_payload(uuid) from public, anon, authenticated;
revoke all on function app_private.user_is_authorized(uuid) from public, anon, authenticated;
revoke all on function app_private.user_is_admin(uuid) from public, anon, authenticated;
revoke all on function app_private.session_is_current(uuid, uuid) from public, anon, authenticated;
revoke all on function app_private.has_active_session() from public, anon, authenticated;
revoke all on function app_private.current_user_is_admin() from public, anon, authenticated;
revoke all on function app_private.can_access_school(uuid, text) from public, anon, authenticated;
revoke all on function app_private.require_active_session() from public, anon, authenticated;
revoke all on function app_private.require_school_editor(uuid) from public, anon, authenticated;
revoke all on function app_private.set_updated_at_and_revision() from public, anon, authenticated;
revoke all on function app_private.legacy_config_value(jsonb, text) from public, anon, authenticated;
revoke all on function app_private.legacy_escola_state(public.escola_dados) from public, anon, authenticated;
revoke all on function app_private.materialize_legacy_owner(text) from public, anon, authenticated;
revoke all on function app_private.mirror_legacy_escola_data() from public, anon, authenticated;

grant usage on schema app_private to authenticated;
grant execute on function app_private.has_active_session() to authenticated;
grant execute on function app_private.current_user_is_admin() to authenticated;
grant execute on function app_private.can_access_school(uuid, text) to authenticated;

revoke all on function public.edge_legacy_login_verify(text, text) from public, anon, authenticated;
revoke all on function public.edge_login_resolve(text) from public, anon, authenticated;
revoke all on function public.edge_legacy_login_complete(text, uuid, text) from public, anon, authenticated;
revoke all on function public.edge_session_activate(uuid, uuid, timestamptz, text) from public, anon, authenticated;
revoke all on function public.edge_session_authorize(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.edge_session_revoke(uuid, uuid) from public, anon, authenticated;
revoke all on function public.edge_claim_google_login(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_refresh_legacy_ownership(text) from public, anon, authenticated;

grant execute on function public.edge_legacy_login_verify(text, text) to service_role;
grant execute on function public.edge_login_resolve(text) to service_role;
grant execute on function public.edge_legacy_login_complete(text, uuid, text) to service_role;
grant execute on function public.edge_session_activate(uuid, uuid, timestamptz, text) to service_role;
grant execute on function public.edge_session_authorize(uuid, uuid, text) to service_role;
grant execute on function public.edge_session_revoke(uuid, uuid) to service_role;
grant execute on function public.edge_claim_google_login(uuid, text, text, text) to service_role;
grant execute on function public.admin_refresh_legacy_ownership(text) to service_role;

revoke all on function public.app_v2_capabilities() from public, anon, authenticated;
revoke all on function public.app_v2_session_context() from public, anon, authenticated;
revoke all on function public.app_v2_end_session() from public, anon, authenticated;
revoke all on function public.app_v2_load_school_state() from public, anon, authenticated;
revoke all on function public.app_v2_save_school_state(bigint, jsonb, uuid) from public, anon, authenticated;
revoke all on function public.app_v2_capture_legacy_browser_state(jsonb, text) from public, anon, authenticated;

grant execute on function public.app_v2_capabilities() to anon, authenticated;
grant execute on function public.app_v2_session_context() to authenticated;
grant execute on function public.app_v2_end_session() to authenticated;
grant execute on function public.app_v2_load_school_state() to authenticated;
grant execute on function public.app_v2_save_school_state(bigint, jsonb, uuid) to authenticated;
grant execute on function public.app_v2_capture_legacy_browser_state(jsonb, text) to authenticated;

commit;
