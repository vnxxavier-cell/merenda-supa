# Server-First Auth Migration Runbook

## Scope

This runbook migrates the application from browser-controlled legacy identity
to Supabase Auth. It is deliberately staged. Legacy tables and IDs remain in
place until the final cutover succeeds.

The authoritative production data source after cutover is Supabase. Browser
storage is only a confirmed cache and must never be treated as a write source.

## Hard stops

Do not apply the final migration until all conditions are true:

1. A fresh external production backup exists and its checksum was verified.
2. The in-database snapshot migration completed successfully.
3. Every legacy user has exactly one Auth UUID mapping.
4. Every `escola_dados` row has the correct UUID owner and canonical document.
5. Every legacy `fichas_custom` payload was deliberately assigned to a school.
6. Every school profile has a captured browser-cache backup where required.
7. The V2 frontend and Edge Functions passed the staging tests.
8. A maintenance window and rollback owner are identified.

`20260903990000_auth_rls_cutover.sql` intentionally aborts if these conditions
are not met. It is not a foundation migration.

## 1. External backup

Install PostgreSQL client tools on a controlled workstation. Set the production
database connection URL only in that shell session:

```powershell
$env:SUPABASE_DB_URL = 'postgresql://...'
.\scripts\backup-supabase.ps1 -OutputDirectory 'D:\secure-backups\cardapiocerto'
```

Store the `.dump`, `.manifest.json` and `.sha256` files outside Git and outside
the deployed Vercel directory. The dump includes sensitive data, including the
legacy credential material. Encrypt it or keep it in approved protected storage.

Record the manifest file name and SHA256 in the migration change record.

## 2. Staging first

Create or use a separate Supabase project. Restore a protected copy of the
production backup there. Do not point `cardapiocerto.vercel.app` at staging.

Install the Supabase CLI and link only the intended staging project:

```powershell
supabase login
supabase link --project-ref YOUR_STAGING_PROJECT_REF
```

Apply migrations `20260903000100` through `20260903000600` in order. Do not
include the final `20260903990000_auth_rls_cutover.sql` in this first pass.
The automated script holds the final migration back and applies only the
foundation set:

```powershell
.\scripts\apply-migrations.ps1 `
  -BackupDumpPath 'D:\secure-backups\cardapiocerto\cardapiocerto-production-<stamp>.dump' `
  -BackupSha256 'EXPECTED_SHA256'
```

The script refuses to run without a verified backup and passing static checks.

The project must have `pgcrypto` available for generated UUIDs. The migration
requests the extension, but verify the result in staging.

## 3. Deploy Edge Functions

Set secrets only in Supabase Edge Function secrets. Never commit a service key:

```powershell
supabase secrets set SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
supabase secrets set SUPABASE_ANON_KEY=YOUR_PUBLISHABLE_KEY
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=YOUR_SERVICE_ROLE_KEY
```

Deploy these functions (the script verifies secrets first):

```powershell
.\scripts\deploy-edge-functions.ps1
```

The functions validate bearer tokens internally where required. `legacy-login`
is intentionally callable without a user JWT because it is the first-login
migration endpoint; it validates password material server-side.

## 4. Auth and data migration

1. Use `legacy-login` to migrate each existing user on successful first login.
2. Confirm `legacy_user_id -> auth.users.id` is one-to-one.
3. Confirm `profiles`, `user_authorizations`, `schools`, memberships and
   `school_state_documents` were created for mapped school users.
4. Capture browser-only legacy settings with `app_v2_capture_legacy_browser_state`.
5. Assign each `technical_sheet_import_queue` record through the protected
   administrator flow. Do not guess ownership of the historical singleton.
6. Compare legacy snapshot counts, legacy rows and canonical documents.
7. Import the legacy domain beside the canonical tables with the server-only
   helper `admin_import_legacy_domain`, then review the returned counts.
8. Preserve `usuarios`, `escola_dados`, `fichas_custom`, snapshots and mapping
   records throughout the rollback period.

## 5. Google authorization

Google sign-in is not an approval mechanism. A new Google identity records a
pending access request with no profile, school membership or data access. The
administrator approves or rejects it in the "Aprovações Google" panel of the
admin page; approval creates the profile, role and school explicitly.

To prevent even an unapproved Auth identity record from being created, configure
the hosted Supabase Auth provider settings or a supported pre-user-creation hook
in the Supabase project. This provider-level setting cannot be safely imposed by
the static Vercel application.

For existing password users, link Google to the same Auth user only through a
controlled authorized flow. Do not create a second profile for the same school.

## 6. Cutover readiness

An active authenticated administrator requests readiness through `admin-users`.
The server checks snapshot, mapping, ownership, state-document and technical-
sheet assignment counts. The administrator supplies the external backup manifest
reference before approving cutover.

Only after a passing readiness result should the final RLS migration be applied.
That migration:

- enables RLS on legacy functional tables;
- removes all existing legacy policies;
- revokes browser grants from legacy tables;
- enables the `server_first_v2` capability gate;
- retains all legacy data and snapshot tables.

## 7. Validation after cutover

Test in staging, then production:

1. Existing password user first login and subsequent Auth login.
2. Existing admin can manage users; school cannot.
3. Unauthorized Google account receives no application access.
4. Authorized Google identity resolves to the same Auth UUID/profile.
5. Login on device B revokes device A application session.
6. Device A cannot read, write or sync after revocation.
7. Device B loads current state directly from Supabase.
8. Revision conflict returns current server state and does not overwrite it.
9. Network failure displays a failed save, not a false success.
10. School A cannot read School B data through table or RPC requests.
11. 2026 data, suppliers, orders, contracts and technical sheets remain present.

## Rollback

The normal rollback before destructive cleanup is application-level:

1. Disable the V2 frontend capability in a controlled server operation.
2. Restore the previous Vercel deployment.
3. Keep legacy tables and snapshots intact.
4. If data restoration is required, restore the verified external database dump
   only under an approved incident procedure.

No migration in this set drops legacy tables, legacy columns or snapshots.
