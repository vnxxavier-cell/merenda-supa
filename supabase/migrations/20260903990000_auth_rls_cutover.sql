-- FINAL CUTOVER MIGRATION -- DO NOT APPLY WITH THE FOUNDATION MIGRATIONS.
--
-- It intentionally aborts unless all users/data have been mapped and an
-- authorized administrator has recorded a backup reference. It does not delete
-- legacy data. Apply it only after the runbook validation checklist succeeds.

begin;

do $cutover_guard$
declare
  v_unmapped_users bigint;
  v_unowned_state bigint;
  v_unassigned_fichas bigint;
  v_missing_documents bigint;
  v_snapshot_count bigint;
  v_approved boolean;
  v_frontend_verified boolean;
  v_pending_browser_captures bigint;
begin
  select count(*) into v_snapshot_count
  from app_private.legacy_snapshot_manifest
  where snapshot_relation in (
    'app_private.usuarios_snapshot_20260903',
    'app_private.escola_dados_snapshot_20260903',
    'app_private.fichas_custom_snapshot_20260903'
  );
  if v_snapshot_count <> 3 then
    raise exception 'Auth/RLS cutover blocked: verified legacy snapshots are missing';
  end if;

  select enabled into v_approved
  from app_private.migration_control
  where control_key = 'legacy_cutover_approved';
  if coalesce(v_approved, false) is not true then
    raise exception 'Auth/RLS cutover blocked: admin backup approval has not been recorded';
  end if;
  select enabled into v_frontend_verified
  from app_private.migration_control
  where control_key = 'frontend_v2_verified';
  if coalesce(v_frontend_verified, false) is not true then
    raise exception 'Auth/RLS cutover blocked: deployed V2 frontend has not been verified';
  end if;

  select count(*) into v_unmapped_users
  from public.usuarios as u
  left join app_private.legacy_user_id_map as m on m.legacy_user_id = u.id::text
  where m.auth_user_id is null;
  if v_unmapped_users > 0 then
    raise exception 'Auth/RLS cutover blocked: % legacy user(s) have no Auth UUID mapping', v_unmapped_users;
  end if;

  select count(*) into v_unowned_state
  from public.escola_dados as e
  left join app_private.legacy_user_id_map as m
    on m.legacy_user_id = coalesce(e.legacy_user_id, e.user_id::text)
  where e.owner_id is null or e.owner_id is distinct from m.auth_user_id;
  if v_unowned_state > 0 then
    raise exception 'Auth/RLS cutover blocked: % legacy school-state row(s) have no verified UUID owner', v_unowned_state;
  end if;

  select count(*) into v_missing_documents
  from public.escola_dados as e
  join public.schools as s on s.legacy_user_id = e.legacy_user_id
  left join public.school_state_documents as d on d.school_id = s.id
  where d.school_id is null;
  if v_missing_documents > 0 then
    raise exception 'Auth/RLS cutover blocked: % canonical school document(s) are missing', v_missing_documents;
  end if;

  select count(*) into v_unassigned_fichas
  from public.technical_sheet_import_queue
  where status <> 'imported' or owner_id is null or school_id is null;
  if v_unassigned_fichas > 0 then
    raise exception 'Auth/RLS cutover blocked: % legacy technical-sheet payload(s) remain unassigned', v_unassigned_fichas;
  end if;

  select count(*) into v_pending_browser_captures
  from app_private.legacy_browser_capture_status
  where status <> 'captured';
  if v_pending_browser_captures > 0 then
    raise exception 'Auth/RLS cutover blocked: % school profile(s) have no legacy browser-cache capture', v_pending_browser_captures;
  end if;
end
$cutover_guard$;

-- Remove every legacy policy only after the guards above pass. This prevents a
-- historical permissive policy from surviving the authenticated cutover.
do $drop_legacy_policies$
declare
  v_table text;
  v_policy text;
begin
  foreach v_table in array array['usuarios', 'escola_dados', 'fichas_custom']
  loop
    for v_policy in
      select policyname
      from pg_policies
      where schemaname = 'public' and tablename = v_table
    loop
      execute format('drop policy if exists %I on public.%I', v_policy, v_table);
    end loop;
  end loop;
end
$drop_legacy_policies$;

alter table public.usuarios enable row level security;
alter table public.escola_dados enable row level security;
alter table public.fichas_custom enable row level security;

-- Legacy tables are retained for recovery only. Browser roles receive
-- no direct privileges after cutover; V2 accesses canonical data via guarded
-- server RPCs.
revoke all on table public.usuarios from anon, authenticated;
revoke all on table public.escola_dados from anon, authenticated;
revoke all on table public.fichas_custom from anon, authenticated;

update public.school_state_documents
set managed_by_legacy = false
where managed_by_legacy;

update app_private.migration_control
set enabled = true,
    note = 'Enabled by 20260903990000_auth_rls_cutover after snapshot, mapping and technical-sheet checks'
where control_key = 'server_first_v2';

commit;
