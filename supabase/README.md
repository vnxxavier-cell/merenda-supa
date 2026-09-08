# Supabase Migration Layout

## Migration order

| Migration | Purpose | Safe to apply before final cutover |
|---|---|---|
| `20260903000100_legacy_snapshots.sql` | Private in-database snapshots of all legacy rows | Yes, after external backup |
| `20260903000200_identity_and_ownership.sql` | Auth UUID bridge, profiles and additive owner columns | Yes |
| `20260903000300_domain_foundation.sql` | Canonical multi-year, supplier, state and tenant tables | Yes |
| `20260903000400_server_first_foundation.sql` | Server-first RPCs, sessions, revisions and legacy materialization | Yes |
| `20260903000500_admin_import_and_integrity.sql` | Admin-only procedures, Google approvals, technical-sheet assignment and tenant checks | Yes |
| `20260903000600_legacy_domain_import.sql` | Idempotent import of legacy suppliers, ingredients, settings, periodicities, previews, contracts and orders | Yes |
| `20260903990000_auth_rls_cutover.sql` | Final legacy RLS cutover | No, only after readiness passes |

All migrations are additive. None drops a legacy table, legacy column,
snapshot or current production data. The domain import copies values beside the
legacy document and never replaces manually edited canonical rows.

## Important

The final migration is intentionally guarded and will abort when any legacy
user, school-state row or technical-sheet payload is not safely mapped. Do not
run every pending migration blindly in production.

Use `docs/MIGRATION_RUNBOOK.md` as the operating procedure.
