-- Phase 6: lossless, idempotent import of the legacy JSON domain into the
-- canonical tables. The legacy document remains authoritative during the
-- transition; canonical rows are materialized side by side and never replace
-- manually edited canonical values.

begin;

create or replace function app_private.safe_numeric(p_value jsonb)
returns numeric
language sql
immutable
set search_path = pg_catalog
as $function$
  select case
    when jsonb_typeof(p_value) = 'number' then (p_value #>> '{}')::numeric
    when jsonb_typeof(p_value) = 'string' and (p_value #>> '{}') ~ '^[0-9]+([.,][0-9]+)?$'
      then replace(p_value #>> '{}', ',', '.')::numeric
    else null
  end
$function$;

create or replace function app_private.legacy_unit_code(p_value jsonb)
returns text
language sql
immutable
set search_path = pg_catalog
as $function$
  select case lower(coalesce(nullif(p_value #>> '{}', ''), ''))
    when 'g' then 'g'
    when 'kg' then 'kg'
    when 'ml' then 'ml'
    when 'l' then 'l'
    when 'un' then 'unit'
    when 'unid' then 'unit'
    when 'unidade' then 'unit'
    when 'dz' then 'dozen'
    when 'dúzia' then 'dozen'
    when 'duzia' then 'dozen'
    when 'maço' then 'bunch'
    when 'maco' then 'bunch'
    when 'pacote' then 'package'
    when 'pct' then 'package'
    when 'cx' then 'case'
    when 'caixa' then 'case'
    else 'kg'
  end
$function$;

create or replace function app_private.legacy_periodicity_weeks(
  p_value jsonb,
  p_periodicities jsonb
)
returns smallint
language sql
immutable
set search_path = pg_catalog
as $function$
  select case
    when jsonb_typeof(p_value) = 'number' then
      greatest(1, least(53, (p_value #>> '{}')::int))::smallint
    when jsonb_typeof(p_value) = 'string' and (p_value #>> '{}') ~ '^[0-9]+$' then
      greatest(1, least(53, (p_value #>> '{}')::int))::smallint
    else coalesce((
      select greatest(1, least(53, (entry ->> 'semanas')::int))::smallint
      from jsonb_array_elements(
        case when jsonb_typeof(p_periodicities) = 'array'
          then p_periodicities
          else '[]'::jsonb
        end
      ) as entry
      where entry ->> 'id' = p_value #>> '{}'
         or lower(coalesce(entry ->> 'nome', '')) = lower(coalesce(p_value #>> '{}', ''))
         and coalesce(entry ->> 'semanas', '') ~ '^[0-9]+$'
      limit 1
    ), 1)::smallint
  end
$function$;

create or replace function app_private.import_legacy_domain(p_legacy_user_id text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_owner_id uuid;
  v_school_id uuid;
  v_school_year_id uuid;
  v_period_id uuid;
  v_suppliers bigint := 0;
  v_ingredients bigint := 0;
  v_links bigint := 0;
  v_settings bigint := 0;
  v_periodicities bigint := 0;
  v_previas bigint := 0;
  v_contracts bigint := 0;
  v_contract_items bigint := 0;
  v_orders bigint := 0;
  v_order_items bigint := 0;
  v_missing_supplier bigint := 0;
begin
  perform app_private.require_service_role();

  select m.auth_user_id into v_owner_id
  from app_private.legacy_user_id_map as m
  where m.legacy_user_id = p_legacy_user_id;
  if v_owner_id is null then
    raise exception using errcode = '22023', message = 'legacy_mapping_not_found';
  end if;

  select s.id into v_school_id
  from public.schools as s
  where s.legacy_user_id = p_legacy_user_id;
  if v_school_id is null then
    raise exception using errcode = '22023', message = 'school_not_materialized';
  end if;

  select y.id into v_school_year_id
  from public.school_years as y
  where y.school_id = v_school_id
  order by y.academic_year
  limit 1;
  select p.id into v_period_id
  from public.planning_periods as p
  where p.school_year_id = v_school_year_id
    and p.code = 'legacy-annual';

  insert into public.suppliers (school_id, legacy_supplier_id, name, metadata)
  select
    v_school_id,
    supplier_entry ->> 'id',
    coalesce(nullif(supplier_entry ->> 'nome', ''), 'Fornecedor legado'),
    coalesce(supplier_entry - 'id' - 'nome', '{}'::jsonb)
  from public.school_state_documents as d
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(d.data -> 'merenda_fornecedores') = 'array'
      then d.data -> 'merenda_fornecedores'
      else '[]'::jsonb
    end
  ) as supplier_entry
  where d.school_id = v_school_id
    and jsonb_typeof(supplier_entry) = 'object'
    and nullif(supplier_entry ->> 'id', '') is not null
  on conflict do nothing;
  get diagnostics v_suppliers = row_count;

  insert into public.school_ingredients (school_id, legacy_name, name, base_unit)
  select
    v_school_id,
    ingredient_key,
    ingredient_key,
    app_private.legacy_unit_code(d.data -> 'merenda_unidades' -> ingredient_key)
  from public.school_state_documents as d
  cross join lateral jsonb_object_keys(
    coalesce(case when jsonb_typeof(d.data -> 'merenda_ing_fornecedores') = 'object'
      then d.data -> 'merenda_ing_fornecedores' end, '{}'::jsonb) ||
    coalesce(case when jsonb_typeof(d.data -> 'merenda_unidades') = 'object'
      then d.data -> 'merenda_unidades' end, '{}'::jsonb) ||
    coalesce(case when jsonb_typeof(d.data -> 'merenda_precos') = 'object'
      then d.data -> 'merenda_precos' end, '{}'::jsonb)
  ) as ingredient_key
  where d.school_id = v_school_id
    and nullif(btrim(ingredient_key), '') is not null
  on conflict do nothing;
  get diagnostics v_ingredients = row_count;

  insert into public.ingredient_suppliers (ingredient_id, supplier_id, active, metadata)
  select
    i.id,
    sp.id,
    true,
    jsonb_build_object('legacy_import', true)
  from public.school_state_documents as d
  join public.school_ingredients as i on i.school_id = d.school_id
  join public.suppliers as sp
    on sp.school_id = d.school_id
   and sp.legacy_supplier_id = d.data -> 'merenda_ing_fornecedores' ->> i.legacy_name
  where d.school_id = v_school_id
    and i.legacy_name is not null
  on conflict do nothing;
  get diagnostics v_links = row_count;

  insert into public.school_ingredient_settings (
    ingredient_id,
    default_package_quantity,
    default_package_unit,
    default_unit_sale_quantity,
    default_unit_sale_label,
    reference_price,
    currency
  )
  select
    i.id,
    app_private.safe_numeric(d.data -> 'merenda_embalagens' -> i.legacy_name),
    i.base_unit,
    case
      when jsonb_typeof(d.data -> 'merenda_ing_unidade_venda' -> i.legacy_name) = 'object'
        then app_private.safe_numeric(d.data -> 'merenda_ing_unidade_venda' -> i.legacy_name -> 'qtdPorUn')
    end,
    case
      when jsonb_typeof(d.data -> 'merenda_ing_unidade_venda' -> i.legacy_name) = 'object'
        then nullif(d.data -> 'merenda_ing_unidade_venda' -> i.legacy_name ->> 'rotulo', '')
    end,
    app_private.safe_numeric(d.data -> 'merenda_precos' -> i.legacy_name),
    'BRL'
  from public.school_state_documents as d
  join public.school_ingredients as i on i.school_id = d.school_id
  where d.school_id = v_school_id
    and i.legacy_name is not null
  on conflict (ingredient_id) do update
    set default_package_quantity = coalesce(
          public.school_ingredient_settings.default_package_quantity,
          excluded.default_package_quantity
        ),
        default_package_unit = coalesce(
          public.school_ingredient_settings.default_package_unit,
          excluded.default_package_unit
        ),
        default_unit_sale_quantity = coalesce(
          public.school_ingredient_settings.default_unit_sale_quantity,
          excluded.default_unit_sale_quantity
        ),
        default_unit_sale_label = coalesce(
          public.school_ingredient_settings.default_unit_sale_label,
          excluded.default_unit_sale_label
        ),
        reference_price = coalesce(
          public.school_ingredient_settings.reference_price,
          excluded.reference_price
        );
  get diagnostics v_settings = row_count;

  if v_period_id is not null then
    insert into public.ingredient_periodicities (
      ingredient_id, planning_period_id, every_weeks, active
    )
    select
      i.id,
      v_period_id,
      app_private.legacy_periodicity_weeks(
        d.data -> 'merenda_ing_periodicidade' -> periodicity_key,
        d.data -> 'merenda_periodicidades'
      ),
      true
    from public.school_state_documents as d
    cross join lateral jsonb_object_keys(
      case when jsonb_typeof(d.data -> 'merenda_ing_periodicidade') = 'object'
        then d.data -> 'merenda_ing_periodicidade'
        else '{}'::jsonb
      end
    ) as periodicity_key
    join public.school_ingredients as i
      on i.school_id = d.school_id
     and i.legacy_name = periodicity_key
    where d.school_id = v_school_id
    on conflict do nothing;
    get diagnostics v_periodicities = row_count;

    insert into public.procurement_previews (
      school_id, planning_period_id, created_by, legacy_id, name, data
    )
    select
      v_school_id,
      v_period_id,
      v_owner_id,
      preview_entry ->> 'id',
      coalesce(nullif(preview_entry ->> 'nome', ''), 'Prévia legada'),
      preview_entry
    from public.school_state_documents as d
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(d.data -> 'merenda_previas_contrato') = 'array'
        then d.data -> 'merenda_previas_contrato'
        else '[]'::jsonb
      end
    ) as preview_entry
    where d.school_id = v_school_id
      and jsonb_typeof(preview_entry) = 'object'
      and nullif(preview_entry ->> 'id', '') is not null
    on conflict do nothing;
    get diagnostics v_previas = row_count;
  end if;

  insert into public.contracts (
    school_id, supplier_id, planning_period_id, legacy_id, contract_number,
    starts_on, ends_on, status, metadata, created_by
  )
  select
    v_school_id,
    sp.id,
    v_period_id,
    contract_entry ->> 'id',
    coalesce(nullif(contract_entry ->> 'nome', ''), contract_entry ->> 'id'),
    case when contract_entry ->> 'data_inicio' ~ '^\d{4}-\d{2}-\d{2}$'
      then (contract_entry ->> 'data_inicio')::date end,
    case when contract_entry ->> 'data_fim' ~ '^\d{4}-\d{2}-\d{2}$'
      then (contract_entry ->> 'data_fim')::date end,
    case when contract_entry ->> 'status' in ('ativa', 'encerrada')
      then contract_entry ->> 'status'
      else 'active' end,
    jsonb_build_object('legacy_import', true),
    v_owner_id
  from public.school_state_documents as d
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(d.data -> 'merenda_licitacoes') = 'array'
      then d.data -> 'merenda_licitacoes'
      else '[]'::jsonb
    end
  ) as contract_entry
  join public.suppliers as sp
    on sp.school_id = v_school_id
   and sp.legacy_supplier_id = contract_entry ->> 'fornecedor_id'
  where d.school_id = v_school_id
    and jsonb_typeof(contract_entry) = 'object'
    and nullif(contract_entry ->> 'id', '') is not null
    and nullif(contract_entry ->> 'fornecedor_id', '') is not null
  on conflict do nothing;
  get diagnostics v_contracts = row_count;

  select count(*) into v_missing_supplier
  from public.school_state_documents as d
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(d.data -> 'merenda_licitacoes') = 'array'
      then d.data -> 'merenda_licitacoes'
      else '[]'::jsonb
    end
  ) as contract_entry
  where d.school_id = v_school_id
    and jsonb_typeof(contract_entry) = 'object'
    and nullif(contract_entry ->> 'fornecedor_id', '') is not null
    and not exists (
      select 1
      from public.suppliers as sp
      where sp.school_id = v_school_id
        and sp.legacy_supplier_id = contract_entry ->> 'fornecedor_id'
    );

  insert into public.contract_items (
    contract_id, ingredient_id, supplier_id, contracted_quantity,
    purchase_unit, winning_price, preliminary_price, currency
  )
  select
    c.id,
    i.id,
    c.supplier_id,
    coalesce(app_private.safe_numeric(item_entry -> 'qtd_contratada'), 0),
    i.base_unit,
    coalesce(app_private.safe_numeric(item_entry -> 'preco_unitario'), 0),
    app_private.safe_numeric(item_entry -> 'preco_previo'),
    'BRL'
  from public.school_state_documents as d
  join public.contracts as c
    on c.school_id = d.school_id
   and c.legacy_id is not null
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(d.data -> 'merenda_licitacoes') = 'array'
      then d.data -> 'merenda_licitacoes'
      else '[]'::jsonb
    end
  ) as contract_entry
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(contract_entry -> 'itens') = 'array'
      then contract_entry -> 'itens'
      else '[]'::jsonb
    end
  ) as item_entry
  join public.school_ingredients as i
    on i.school_id = d.school_id
   and i.legacy_name = item_entry ->> 'ingrediente'
  where d.school_id = v_school_id
    and c.legacy_id = contract_entry ->> 'id'
    and jsonb_typeof(item_entry) = 'object'
  on conflict do nothing;
  get diagnostics v_contract_items = row_count;

  insert into public.purchase_orders (
    school_id, supplier_id, contract_id, planning_period_id, legacy_id,
    order_number, status, issued_on, metadata, created_by
  )
  select
    v_school_id,
    sp.id,
    c.id,
    v_period_id,
    order_entry ->> 'id',
    order_entry ->> 'id',
    'issued',
    case when order_entry ->> 'data_expedicao' ~ '^\d{4}-\d{2}-\d{2}$'
      then (order_entry ->> 'data_expedicao')::date end,
    order_entry,
    v_owner_id
  from public.school_state_documents as d
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(d.data -> 'merenda_ordens_expedidas') = 'array'
      then d.data -> 'merenda_ordens_expedidas'
      else '[]'::jsonb
    end
  ) as order_entry
  join public.suppliers as sp
    on sp.school_id = v_school_id
   and sp.legacy_supplier_id = order_entry ->> 'fornecedor_id'
  left join public.contracts as c
    on c.school_id = v_school_id
   and c.legacy_id = order_entry ->> 'licitacao_id'
  where d.school_id = v_school_id
    and jsonb_typeof(order_entry) = 'object'
    and nullif(order_entry ->> 'id', '') is not null
    and nullif(order_entry ->> 'fornecedor_id', '') is not null
  on conflict do nothing;
  get diagnostics v_orders = row_count;

  insert into public.purchase_order_items (
    purchase_order_id, ingredient_id, supplier_id, contract_item_id,
    requested_quantity, purchase_unit, unit_price, currency, scheduled_dates
  )
  select
    po.id,
    i.id,
    po.supplier_id,
    ci.id,
    coalesce(app_private.safe_numeric(item_entry -> 'qtd_solicitada'), 0),
    i.base_unit,
    app_private.safe_numeric(item_entry -> 'preco_unitario'),
    'BRL',
    case when jsonb_typeof(item_entry -> 'dias') = 'array'
      then item_entry -> 'dias'
      else '[]'::jsonb end
  from public.school_state_documents as d
  join public.purchase_orders as po
    on po.school_id = d.school_id
   and po.legacy_id is not null
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(d.data -> 'merenda_ordens_expedidas') = 'array'
      then d.data -> 'merenda_ordens_expedidas'
      else '[]'::jsonb
    end
  ) as order_entry
  cross join lateral jsonb_array_elements(
    case when jsonb_typeof(order_entry -> 'itens') = 'array'
      then order_entry -> 'itens'
      else '[]'::jsonb
    end
  ) as item_entry
  join public.school_ingredients as i
    on i.school_id = d.school_id
   and i.legacy_name = item_entry ->> 'ingrediente'
  left join public.contract_items as ci
    on ci.contract_id = po.contract_id
   and ci.ingredient_id = i.id
  where d.school_id = v_school_id
    and po.legacy_id = order_entry ->> 'id'
    and jsonb_typeof(item_entry) = 'object'
  on conflict do nothing;
  get diagnostics v_order_items = row_count;

  return jsonb_build_object(
    'legacy_user_id', p_legacy_user_id,
    'school_id', v_school_id,
    'suppliers_imported', v_suppliers,
    'ingredients_imported', v_ingredients,
    'supplier_links_imported', v_links,
    'settings_imported', v_settings,
    'periodicities_imported', v_periodicities,
    'previews_imported', v_previas,
    'contracts_imported', v_contracts,
    'contract_items_imported', v_contract_items,
    'orders_imported', v_orders,
    'order_items_imported', v_order_items,
    'contracts_missing_supplier', v_missing_supplier
  );
end
$function$;

create or replace function public.admin_import_legacy_domain(
  p_legacy_user_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog
as $function$
declare
  v_results jsonb := '[]'::jsonb;
  v_legacy_id text;
begin
  perform app_private.require_service_role();
  for v_legacy_id in
    select legacy_user_id
    from app_private.legacy_user_id_map
    where p_legacy_user_id is null or legacy_user_id = p_legacy_user_id
  loop
    v_results := v_results || jsonb_build_array(
      app_private.import_legacy_domain(v_legacy_id)
    );
  end loop;
  return jsonb_build_object('ok', true, 'results', v_results);
end
$function$;

revoke all on function app_private.safe_numeric(jsonb) from public, anon, authenticated;
revoke all on function app_private.legacy_unit_code(jsonb) from public, anon, authenticated;
revoke all on function app_private.legacy_periodicity_weeks(jsonb, jsonb) from public, anon, authenticated;
revoke all on function app_private.import_legacy_domain(text) from public, anon, authenticated;
revoke all on function public.admin_import_legacy_domain(text) from public, anon, authenticated;
grant execute on function public.admin_import_legacy_domain(text) to service_role;

commit;
