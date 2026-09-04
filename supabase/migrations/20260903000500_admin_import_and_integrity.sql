-- Phase 5: server-only administration helpers and tenant-integrity checks.
-- This migration is additive. It does not enable RLS on legacy tables yet.

begin;

create or replace function app_private.assert_service_admin(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = pg_catalog
as $function$
begin
  perform app_private.require_service_role();
  if not app_private.session_is_current(p_actor_auth_user_id, p_actor_session_id)
     or not app_private.user_is_admin(p_actor_auth_user_id) then
    raise exception using errcode = '42501', message = 'administrator_session_required';
  end if;
end
$function$;

create or replace function public.edge_admin_profile_get(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid,
  p_profile_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
begin
  perform app_private.assert_service_admin(p_actor_auth_user_id, p_actor_session_id);
  if not exists (select 1 from public.profiles where user_id = p_profile_id) then
    return null;
  end if;
  return app_private.profile_payload(p_profile_id);
end
$function$;

create or replace function public.edge_admin_profiles_list(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid,
  p_limit integer default 50,
  p_offset integer default 0,
  p_query text default null,
  p_include_inactive boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_items jsonb;
  v_total bigint;
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_query text := nullif(btrim(coalesce(p_query, '')), '');
begin
  perform app_private.assert_service_admin(p_actor_auth_user_id, p_actor_session_id);
  select count(*) into v_total
  from public.profiles as p
  join app_private.user_authorizations as a on a.user_id = p.user_id
  where (p_include_inactive or (p.status = 'active' and a.active))
    and (
      v_query is null
      or p.display_name ilike '%' || v_query || '%'
      or p.login ilike '%' || v_query || '%'
      or p.auth_email ilike '%' || v_query || '%'
      or p.legacy_user_id ilike '%' || v_query || '%'
    );

  select coalesce(jsonb_agg(item.payload order by item.display_name, item.login), '[]'::jsonb)
  into v_items
  from (
    select p.display_name, p.login, app_private.profile_payload(p.user_id) as payload
    from public.profiles as p
    join app_private.user_authorizations as a on a.user_id = p.user_id
    where (p_include_inactive or (p.status = 'active' and a.active))
      and (
        v_query is null
        or p.display_name ilike '%' || v_query || '%'
        or p.login ilike '%' || v_query || '%'
        or p.auth_email ilike '%' || v_query || '%'
        or p.legacy_user_id ilike '%' || v_query || '%'
      )
    order by p.display_name, p.login
    limit v_limit offset v_offset
  ) as item;

  return jsonb_build_object('items', v_items, 'total', v_total);
end
$function$;

create or replace function public.edge_admin_profile_create(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid,
  p_target_auth_user_id uuid,
  p_auth_email text,
  p_login text,
  p_display_name text,
  p_role text,
  p_expires_at date default null,
  p_google_email text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_role text;
  v_school_id uuid;
begin
  perform app_private.assert_service_admin(p_actor_auth_user_id, p_actor_session_id);
  if not exists (select 1 from auth.users where id = p_target_auth_user_id) then
    raise exception using errcode = '22023', message = 'auth_user_not_found';
  end if;
  if nullif(btrim(p_login), '') is null or nullif(btrim(p_display_name), '') is null then
    raise exception using errcode = '22023', message = 'profile_name_and_login_required';
  end if;
  v_role := case lower(btrim(p_role))
    when 'admin' then 'admin'
    when 'escola' then 'school'
    when 'school' then 'school'
    else null
  end;
  if v_role is null then
    raise exception using errcode = '22023', message = 'invalid_role';
  end if;

  insert into public.profiles (
    user_id, login, display_name, auth_email, google_email, status
  ) values (
    p_target_auth_user_id,
    btrim(p_login),
    btrim(p_display_name),
    nullif(lower(btrim(p_auth_email)), ''),
    nullif(lower(btrim(p_google_email)), ''),
    'active'
  )
  on conflict (user_id) do update
    set login = excluded.login,
        display_name = excluded.display_name,
        auth_email = excluded.auth_email,
        google_email = excluded.google_email,
        status = 'active';

  insert into app_private.user_authorizations (
    user_id, app_role, active, expires_at, granted_by
  ) values (
    p_target_auth_user_id,
    v_role,
    true,
    case when p_expires_at is null then null else p_expires_at::timestamptz + interval '1 day' end,
    p_actor_auth_user_id
  )
  on conflict (user_id) do update
    set app_role = excluded.app_role,
        active = true,
        expires_at = excluded.expires_at,
        granted_by = excluded.granted_by;

  if v_role = 'school' then
    select m.school_id into v_school_id
    from public.school_memberships as m
    where m.user_id = p_target_auth_user_id and m.active
    order by case m.membership_role when 'owner' then 0 else 1 end, m.created_at
    limit 1;
    if v_school_id is null then
      insert into public.schools (name, created_by)
      values (btrim(p_display_name), p_target_auth_user_id)
      returning id into v_school_id;
      insert into public.school_memberships (school_id, user_id, membership_role)
      values (v_school_id, p_target_auth_user_id, 'owner');
      insert into public.school_state_documents (school_id, owner_id, data, managed_by_legacy)
      values (v_school_id, p_target_auth_user_id, '{}'::jsonb, false);
    end if;
  end if;

  return app_private.profile_payload(p_target_auth_user_id);
end
$function$;

create or replace function public.edge_admin_profile_update(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid,
  p_profile_id uuid,
  p_changes jsonb,
  p_expected_revision bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_unknown_keys text[];
  v_current public.profiles%rowtype;
  v_role text;
  v_active boolean;
  v_expires_at timestamptz;
begin
  perform app_private.assert_service_admin(p_actor_auth_user_id, p_actor_session_id);
  if jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    raise exception using errcode = '22023', message = 'profile_changes_required';
  end if;
  select array_agg(key) into v_unknown_keys
  from jsonb_object_keys(p_changes) as keys(key)
  where key not in ('login', 'display_name', 'auth_email', 'google_email', 'role', 'active', 'expires_at');
  if v_unknown_keys is not null then
    raise exception using errcode = '22023', message = 'profile_change_not_allowed';
  end if;

  select p.* into v_current
  from public.profiles as p
  where p.user_id = p_profile_id
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'profile_not_found';
  end if;
  if p_expected_revision is not null and v_current.revision <> p_expected_revision then
    raise exception using errcode = '40001', message = 'profile_revision_conflict';
  end if;

  if p_changes ? 'login' and nullif(btrim(p_changes ->> 'login'), '') is null then
    raise exception using errcode = '22023', message = 'login_invalid';
  end if;
  if p_changes ? 'display_name' and nullif(btrim(p_changes ->> 'display_name'), '') is null then
    raise exception using errcode = '22023', message = 'display_name_invalid';
  end if;

  update public.profiles
  set login = case when p_changes ? 'login' then btrim(p_changes ->> 'login') else login end,
      display_name = case when p_changes ? 'display_name' then btrim(p_changes ->> 'display_name') else display_name end,
      auth_email = case when p_changes ? 'auth_email' then nullif(lower(btrim(p_changes ->> 'auth_email')), '') else auth_email end,
      google_email = case when p_changes ? 'google_email' then nullif(lower(btrim(p_changes ->> 'google_email')), '') else google_email end,
      status = case
        when p_changes ? 'active' and coalesce((p_changes ->> 'active')::boolean, false) then 'active'
        when p_changes ? 'active' then 'disabled'
        else status
      end
  where user_id = p_profile_id;

  if p_changes ? 'role' then
    v_role := case lower(btrim(p_changes ->> 'role'))
      when 'admin' then 'admin'
      when 'escola' then 'school'
      when 'school' then 'school'
      else null
    end;
    if v_role is null then
      raise exception using errcode = '22023', message = 'invalid_role';
    end if;
  end if;
  if p_changes ? 'active' then
    v_active := coalesce((p_changes ->> 'active')::boolean, false);
  else
    select active into v_active from app_private.user_authorizations where user_id = p_profile_id;
  end if;
  if p_changes ? 'expires_at' then
    begin
      v_expires_at := nullif(p_changes ->> 'expires_at', '')::date::timestamptz + interval '1 day';
    exception when others then
      raise exception using errcode = '22023', message = 'expires_at_invalid';
    end;
  else
    select expires_at into v_expires_at from app_private.user_authorizations where user_id = p_profile_id;
  end if;
  update app_private.user_authorizations
  set app_role = coalesce(v_role, app_role),
      active = v_active,
      expires_at = v_expires_at,
      granted_by = p_actor_auth_user_id
  where user_id = p_profile_id;

  if p_changes ? 'active' and not v_active then
    delete from app_private.user_sessions
    where user_id = p_profile_id;
  end if;
  return app_private.profile_payload(p_profile_id);
end
$function$;

create or replace function public.edge_admin_profile_deactivate(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid,
  p_profile_id uuid,
  p_expected_revision bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
begin
  return public.edge_admin_profile_update(
    p_actor_auth_user_id,
    p_actor_session_id,
    p_profile_id,
    jsonb_build_object('active', false),
    p_expected_revision
  );
end
$function$;

-- Google OAuth may create an Auth identity, but it gets no profile or school
-- access until this administrator approval path completes.
create or replace function public.edge_admin_google_requests_list(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid,
  p_include_resolved boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_requests jsonb;
begin
  perform app_private.assert_service_admin(p_actor_auth_user_id, p_actor_session_id);
  select coalesce(jsonb_agg(jsonb_build_object(
    'auth_user_id', r.auth_user_id::text,
    'google_email', r.google_email,
    'display_name', r.display_name,
    'status', r.status,
    'requested_at', r.requested_at,
    'reviewed_at', r.reviewed_at,
    'note', r.note
  ) order by r.requested_at desc), '[]'::jsonb)
  into v_requests
  from app_private.google_access_requests as r
  where p_include_resolved or r.status = 'pending';
  return v_requests;
end
$function$;

create or replace function public.edge_admin_google_request_approve(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid,
  p_request_auth_user_id uuid,
  p_login text,
  p_display_name text,
  p_role text default 'escola',
  p_expires_at date default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_request app_private.google_access_requests%rowtype;
  v_profile jsonb;
begin
  perform app_private.assert_service_admin(p_actor_auth_user_id, p_actor_session_id);
  select r.* into v_request
  from app_private.google_access_requests as r
  where r.auth_user_id = p_request_auth_user_id
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'google_request_not_found';
  end if;
  if v_request.status = 'rejected' then
    raise exception using errcode = '22023', message = 'google_request_rejected';
  end if;
  if nullif(btrim(p_login), '') is null or nullif(btrim(p_display_name), '') is null then
    raise exception using errcode = '22023', message = 'profile_name_and_login_required';
  end if;
  v_profile := public.edge_admin_profile_create(
    p_actor_auth_user_id,
    p_actor_session_id,
    p_request_auth_user_id,
    v_request.google_email,
    p_login,
    p_display_name,
    p_role,
    p_expires_at,
    v_request.google_email
  );
  update public.profiles
  set google_subject = v_request.google_subject
  where user_id = p_request_auth_user_id;
  update app_private.google_access_requests
  set status = 'approved',
      reviewed_at = clock_timestamp(),
      reviewed_by = p_actor_auth_user_id,
      note = p_note
  where auth_user_id = p_request_auth_user_id;
  return app_private.profile_payload(p_request_auth_user_id);
end
$function$;

create or replace function public.edge_admin_google_request_reject(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid,
  p_request_auth_user_id uuid,
  p_note text default null
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $function$
begin
  perform app_private.assert_service_admin(p_actor_auth_user_id, p_actor_session_id);
  update app_private.google_access_requests
  set status = 'rejected',
      reviewed_at = clock_timestamp(),
      reviewed_by = p_actor_auth_user_id,
      note = p_note
  where auth_user_id = p_request_auth_user_id
    and status = 'pending';
  return found;
end
$function$;

create or replace function public.edge_admin_assign_legacy_fichas(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid,
  p_legacy_fichas_custom_id integer,
  p_owner_id uuid,
  p_school_id uuid,
  p_name text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_queue public.technical_sheet_import_queue%rowtype;
  v_sheet_id uuid;
begin
  perform app_private.assert_service_admin(p_actor_auth_user_id, p_actor_session_id);
  if nullif(btrim(p_name), '') is null then
    raise exception using errcode = '22023', message = 'technical_sheet_name_required';
  end if;
  if not exists (
    select 1 from public.school_memberships
    where school_id = p_school_id and user_id = p_owner_id and active
  ) then
    raise exception using errcode = '22023', message = 'owner_not_member_of_school';
  end if;
  select q.* into v_queue
  from public.technical_sheet_import_queue as q
  where q.legacy_fichas_custom_id = p_legacy_fichas_custom_id
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'legacy_fichas_source_not_found';
  end if;
  update public.technical_sheet_import_queue
  set owner_id = p_owner_id,
      school_id = p_school_id,
      status = 'assigned',
      assigned_at = clock_timestamp(),
      assigned_by = p_actor_auth_user_id,
      notes = p_notes
  where id = v_queue.id;
  insert into public.technical_sheets (
    school_id, owner_id, legacy_fichas_custom_id, name, data, imported_from_legacy
  ) values (
    p_school_id, p_owner_id, p_legacy_fichas_custom_id, btrim(p_name), v_queue.data, true
  )
  on conflict (legacy_fichas_custom_id) where legacy_fichas_custom_id is not null
  do update set school_id = excluded.school_id,
                owner_id = excluded.owner_id,
                name = excluded.name,
                data = excluded.data
  returning id into v_sheet_id;
  update public.technical_sheet_import_queue
  set status = 'imported'
  where id = v_queue.id;
  return jsonb_build_object('ok', true, 'technical_sheet_id', v_sheet_id::text);
end
$function$;

-- Tenant consistency checks prevent cross-school links even for privileged
-- application writes. They complement, rather than replace, RLS.
create or replace function app_private.assert_ingredient_supplier_tenant()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_ingredient_school uuid;
  v_supplier_school uuid;
begin
  select school_id into v_ingredient_school from public.school_ingredients where id = new.ingredient_id;
  select school_id into v_supplier_school from public.suppliers where id = new.supplier_id;
  if v_ingredient_school is null or v_supplier_school is null or v_ingredient_school <> v_supplier_school then
    raise exception using errcode = '23514', message = 'ingredient_supplier_school_mismatch';
  end if;
  return new;
end
$function$;

create or replace function app_private.assert_contract_tenant()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_supplier_school uuid;
  v_period_school uuid;
begin
  select school_id into v_supplier_school from public.suppliers where id = new.supplier_id;
  if v_supplier_school is null or v_supplier_school <> new.school_id then
    raise exception using errcode = '23514', message = 'contract_supplier_school_mismatch';
  end if;
  if new.planning_period_id is not null then
    select y.school_id into v_period_school
    from public.planning_periods p join public.school_years y on y.id = p.school_year_id
    where p.id = new.planning_period_id;
    if v_period_school is null or v_period_school <> new.school_id then
      raise exception using errcode = '23514', message = 'contract_period_school_mismatch';
    end if;
  end if;
  return new;
end
$function$;

create or replace function app_private.assert_purchase_order_tenant()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_supplier_school uuid;
  v_contract_school uuid;
  v_contract_supplier uuid;
begin
  select school_id into v_supplier_school from public.suppliers where id = new.supplier_id;
  if v_supplier_school is null or v_supplier_school <> new.school_id then
    raise exception using errcode = '23514', message = 'order_supplier_school_mismatch';
  end if;
  if new.contract_id is not null then
    select school_id, supplier_id into v_contract_school, v_contract_supplier
    from public.contracts where id = new.contract_id;
    if v_contract_school is null or v_contract_school <> new.school_id or v_contract_supplier <> new.supplier_id then
      raise exception using errcode = '23514', message = 'order_contract_mismatch';
    end if;
  end if;
  return new;
end
$function$;

create or replace function app_private.assert_purchase_order_item_tenant()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_order_school uuid;
  v_order_supplier uuid;
  v_ingredient_school uuid;
begin
  select school_id, supplier_id into v_order_school, v_order_supplier
  from public.purchase_orders where id = new.purchase_order_id;
  select school_id into v_ingredient_school from public.school_ingredients where id = new.ingredient_id;
  if v_order_school is null or v_ingredient_school is null
     or v_order_school <> v_ingredient_school
     or v_order_supplier <> new.supplier_id then
    raise exception using errcode = '23514', message = 'order_item_tenant_mismatch';
  end if;
  return new;
end
$function$;

create or replace function app_private.assert_contract_item_tenant()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_contract_school uuid;
  v_contract_supplier uuid;
  v_ingredient_school uuid;
begin
  select school_id, supplier_id into v_contract_school, v_contract_supplier
  from public.contracts where id = new.contract_id;
  select school_id into v_ingredient_school from public.school_ingredients where id = new.ingredient_id;
  if v_contract_school is null or v_ingredient_school is null
     or v_contract_school <> v_ingredient_school
     or v_contract_supplier <> new.supplier_id then
    raise exception using errcode = '23514', message = 'contract_item_tenant_mismatch';
  end if;
  return new;
end
$function$;

create or replace function app_private.assert_ingredient_periodicity_tenant()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_ingredient_school uuid;
  v_period_school uuid;
begin
  select school_id into v_ingredient_school from public.school_ingredients where id = new.ingredient_id;
  select y.school_id into v_period_school
  from public.planning_periods as p
  join public.school_years as y on y.id = p.school_year_id
  where p.id = new.planning_period_id;
  if v_ingredient_school is null or v_period_school is null or v_ingredient_school <> v_period_school then
    raise exception using errcode = '23514', message = 'ingredient_periodicity_tenant_mismatch';
  end if;
  return new;
end
$function$;

create or replace function app_private.assert_inventory_movement_tenant()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_ingredient_school uuid;
  v_order_school uuid;
begin
  select school_id into v_ingredient_school from public.school_ingredients where id = new.ingredient_id;
  if v_ingredient_school is null or v_ingredient_school <> new.school_id then
    raise exception using errcode = '23514', message = 'inventory_ingredient_school_mismatch';
  end if;
  if new.purchase_order_item_id is not null then
    select o.school_id into v_order_school
    from public.purchase_order_items as i
    join public.purchase_orders as o on o.id = i.purchase_order_id
    where i.id = new.purchase_order_item_id;
    if v_order_school is null or v_order_school <> new.school_id then
      raise exception using errcode = '23514', message = 'inventory_order_item_school_mismatch';
    end if;
  end if;
  return new;
end
$function$;

do $tenant_integrity_triggers$
begin
  if not exists (select 1 from pg_trigger where tgrelid = 'public.ingredient_suppliers'::regclass and tgname = 'app_assert_ingredient_supplier_tenant' and not tgisinternal) then
    create trigger app_assert_ingredient_supplier_tenant
      before insert or update on public.ingredient_suppliers
      for each row execute function app_private.assert_ingredient_supplier_tenant();
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.contracts'::regclass and tgname = 'app_assert_contract_tenant' and not tgisinternal) then
    create trigger app_assert_contract_tenant
      before insert or update on public.contracts
      for each row execute function app_private.assert_contract_tenant();
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.purchase_orders'::regclass and tgname = 'app_assert_purchase_order_tenant' and not tgisinternal) then
    create trigger app_assert_purchase_order_tenant
      before insert or update on public.purchase_orders
      for each row execute function app_private.assert_purchase_order_tenant();
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.purchase_order_items'::regclass and tgname = 'app_assert_purchase_order_item_tenant' and not tgisinternal) then
    create trigger app_assert_purchase_order_item_tenant
      before insert or update on public.purchase_order_items
      for each row execute function app_private.assert_purchase_order_item_tenant();
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.contract_items'::regclass and tgname = 'app_assert_contract_item_tenant' and not tgisinternal) then
    create trigger app_assert_contract_item_tenant
      before insert or update on public.contract_items
      for each row execute function app_private.assert_contract_item_tenant();
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.ingredient_periodicities'::regclass and tgname = 'app_assert_ingredient_periodicity_tenant' and not tgisinternal) then
    create trigger app_assert_ingredient_periodicity_tenant
      before insert or update on public.ingredient_periodicities
      for each row execute function app_private.assert_ingredient_periodicity_tenant();
  end if;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.inventory_movements'::regclass and tgname = 'app_assert_inventory_movement_tenant' and not tgisinternal) then
    create trigger app_assert_inventory_movement_tenant
      before insert or update on public.inventory_movements
      for each row execute function app_private.assert_inventory_movement_tenant();
  end if;
end
$tenant_integrity_triggers$;

create or replace function app_private.auth_cutover_readiness()
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog
as $function$
declare
  v_snapshot_count bigint;
  v_unmapped_users bigint;
  v_unowned_state bigint;
  v_missing_documents bigint;
  v_unassigned_fichas bigint;
  v_pending_browser_captures bigint;
  v_frontend_verified boolean;
begin
  select count(*) into v_snapshot_count
  from app_private.legacy_snapshot_manifest
  where snapshot_relation in (
    'app_private.usuarios_snapshot_20260903',
    'app_private.escola_dados_snapshot_20260903',
    'app_private.fichas_custom_snapshot_20260903'
  );
  select count(*) into v_unmapped_users
  from public.usuarios as u
  left join app_private.legacy_user_id_map as m on m.legacy_user_id = u.id::text
  where m.auth_user_id is null;
  select count(*) into v_unowned_state
  from public.escola_dados as e
  left join app_private.legacy_user_id_map as m
    on m.legacy_user_id = coalesce(e.legacy_user_id, e.user_id::text)
  where e.owner_id is null or e.owner_id is distinct from m.auth_user_id;
  select count(*) into v_missing_documents
  from public.escola_dados as e
  join public.schools as s on s.legacy_user_id = e.legacy_user_id
  left join public.school_state_documents as d on d.school_id = s.id
  where d.school_id is null;
  select count(*) into v_unassigned_fichas
  from public.technical_sheet_import_queue
  where status <> 'imported' or owner_id is null or school_id is null;
  select count(*) into v_pending_browser_captures
  from app_private.legacy_browser_capture_status
  where status <> 'captured';
  select enabled into v_frontend_verified
  from app_private.migration_control
  where control_key = 'frontend_v2_verified';
  return jsonb_build_object(
    'ready', v_snapshot_count = 3
      and v_unmapped_users = 0
      and v_unowned_state = 0
      and v_missing_documents = 0
      and v_unassigned_fichas = 0
      and v_pending_browser_captures = 0
      and coalesce(v_frontend_verified, false),
    'snapshots', v_snapshot_count,
    'unmapped_users', v_unmapped_users,
    'unowned_legacy_state', v_unowned_state,
    'missing_state_documents', v_missing_documents,
    'unassigned_technical_sheet_payloads', v_unassigned_fichas,
    'pending_browser_cache_captures', v_pending_browser_captures,
    'frontend_v2_verified', coalesce(v_frontend_verified, false)
  );
end
$function$;

create or replace function public.edge_auth_cutover_readiness(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
begin
  perform app_private.assert_service_admin(p_actor_auth_user_id, p_actor_session_id);
  return app_private.auth_cutover_readiness();
end
$function$;

create or replace function public.edge_auth_cutover_approve(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid,
  p_backup_reference text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_readiness jsonb;
  v_backup_reference text := nullif(btrim(p_backup_reference), '');
begin
  perform app_private.assert_service_admin(p_actor_auth_user_id, p_actor_session_id);
  if v_backup_reference is null then
    raise exception using errcode = '22023', message = 'backup_reference_required';
  end if;
  v_readiness := app_private.auth_cutover_readiness();
  if coalesce((v_readiness ->> 'ready')::boolean, false) is not true then
    raise exception using errcode = '55000', message = 'auth_cutover_not_ready';
  end if;
  update app_private.migration_control
  set enabled = true,
      note = left('Approved backup: ' || v_backup_reference, 500),
      updated_at = clock_timestamp()
  where control_key = 'legacy_cutover_approved';
  return v_readiness || jsonb_build_object('approved', true);
end
$function$;

create or replace function public.edge_frontend_v2_verify(
  p_actor_auth_user_id uuid,
  p_actor_session_id uuid,
  p_deployment_reference text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog
as $function$
begin
  perform app_private.assert_service_admin(p_actor_auth_user_id, p_actor_session_id);
  if nullif(btrim(p_deployment_reference), '') is null then
    raise exception using errcode = '22023', message = 'deployment_reference_required';
  end if;
  update app_private.migration_control
  set enabled = true,
      note = left('Verified V2 deployment: ' || btrim(p_deployment_reference), 500),
      updated_at = clock_timestamp()
  where control_key = 'frontend_v2_verified';
  return found;
end
$function$;

revoke all on function app_private.assert_service_admin(uuid, uuid) from public, anon, authenticated;
revoke all on function app_private.auth_cutover_readiness() from public, anon, authenticated;
revoke all on function app_private.assert_ingredient_supplier_tenant() from public, anon, authenticated;
revoke all on function app_private.assert_contract_tenant() from public, anon, authenticated;
revoke all on function app_private.assert_purchase_order_tenant() from public, anon, authenticated;
revoke all on function app_private.assert_purchase_order_item_tenant() from public, anon, authenticated;
revoke all on function app_private.assert_contract_item_tenant() from public, anon, authenticated;
revoke all on function app_private.assert_ingredient_periodicity_tenant() from public, anon, authenticated;
revoke all on function app_private.assert_inventory_movement_tenant() from public, anon, authenticated;

revoke all on function public.edge_admin_profile_get(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.edge_admin_profiles_list(uuid, uuid, integer, integer, text, boolean) from public, anon, authenticated;
revoke all on function public.edge_admin_profile_create(uuid, uuid, uuid, text, text, text, text, date, text) from public, anon, authenticated;
revoke all on function public.edge_admin_profile_update(uuid, uuid, uuid, jsonb, bigint) from public, anon, authenticated;
revoke all on function public.edge_admin_profile_deactivate(uuid, uuid, uuid, bigint) from public, anon, authenticated;
revoke all on function public.edge_admin_google_requests_list(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.edge_admin_google_request_approve(uuid, uuid, uuid, text, text, text, date, text) from public, anon, authenticated;
revoke all on function public.edge_admin_google_request_reject(uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.edge_admin_assign_legacy_fichas(uuid, uuid, integer, uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.edge_auth_cutover_readiness(uuid, uuid) from public, anon, authenticated;
revoke all on function public.edge_auth_cutover_approve(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.edge_frontend_v2_verify(uuid, uuid, text) from public, anon, authenticated;

grant execute on function public.edge_admin_profile_get(uuid, uuid, uuid) to service_role;
grant execute on function public.edge_admin_profiles_list(uuid, uuid, integer, integer, text, boolean) to service_role;
grant execute on function public.edge_admin_profile_create(uuid, uuid, uuid, text, text, text, text, date, text) to service_role;
grant execute on function public.edge_admin_profile_update(uuid, uuid, uuid, jsonb, bigint) to service_role;
grant execute on function public.edge_admin_profile_deactivate(uuid, uuid, uuid, bigint) to service_role;
grant execute on function public.edge_admin_google_requests_list(uuid, uuid, boolean) to service_role;
grant execute on function public.edge_admin_google_request_approve(uuid, uuid, uuid, text, text, text, date, text) to service_role;
grant execute on function public.edge_admin_google_request_reject(uuid, uuid, uuid, text) to service_role;
grant execute on function public.edge_admin_assign_legacy_fichas(uuid, uuid, integer, uuid, uuid, text, text) to service_role;
grant execute on function public.edge_auth_cutover_readiness(uuid, uuid) to service_role;
grant execute on function public.edge_auth_cutover_approve(uuid, uuid, text) to service_role;
grant execute on function public.edge_frontend_v2_verify(uuid, uuid, text) to service_role;

commit;
