$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$migrationsDir = Join-Path $root 'supabase/migrations'
$migrations = Get-ChildItem -LiteralPath $migrationsDir -Filter '*.sql' | Sort-Object Name

if ($migrations.Count -lt 6) {
  throw "Expected at least 6 migration files, found $($migrations.Count)."
}

$protectedTables = @('usuarios', 'escola_dados', 'fichas_custom')
$forbiddenPattern = '(?i)\bdrop\s+table\s+(if\s+exists\s+)?(public\.)?(usuarios|escola_dados|fichas_custom)\b|\btruncate\s+(table\s+)?(only\s+)?(public\.)?(usuarios|escola_dados|fichas_custom)\b'
$auditPattern = '(?i)audit_log|write_audit|login_history|session_history'

$expectedOrder = @(
  '20260903000100_legacy_snapshots.sql',
  '20260903000200_identity_and_ownership.sql',
  '20260903000300_domain_foundation.sql',
  '20260903000400_server_first_foundation.sql',
  '20260903000500_admin_import_and_integrity.sql',
  '20260903000600_legacy_domain_import.sql',
  '20260903990000_auth_rls_cutover.sql'
)

$actualOrder = $migrations | ForEach-Object { $_.Name }
foreach ($expected in $expectedOrder) {
  if ($actualOrder -notcontains $expected) {
    throw "Required migration is missing: $expected"
  }
}

foreach ($file in $migrations) {
  $raw = [System.IO.File]::ReadAllText($file.FullName)
  $begin = ([regex]::Matches($raw, '(?im)^begin;\s*$')).Count
  $commit = ([regex]::Matches($raw, '(?im)^commit;\s*$')).Count
  if ($begin -ne 1 -or $commit -ne 1) {
    throw "Transaction envelope mismatch in $($file.Name): begin=$begin commit=$commit"
  }
  $functionTags = ([regex]::Matches($raw, '\$function\$')).Count
  if ($functionTags % 2 -ne 0) {
    throw "Unbalanced function body tags in $($file.Name)"
  }
  if ($raw -match $forbiddenPattern) {
    throw "Destructive statement against a legacy table found in $($file.Name)"
  }
  if ($raw -match $auditPattern) {
    throw "Audit or history artifact found in $($file.Name)"
  }
}

$cutover = [System.IO.File]::ReadAllText((Join-Path $migrationsDir '20260903990000_auth_rls_cutover.sql'))
if ($cutover -notmatch 'cutover blocked') {
  throw 'The final cutover migration must keep its guard messages.'
}
if ($cutover -notmatch 'enable row level security') {
  throw 'The final cutover migration must enable RLS on the legacy tables.'
}

"SQL static check passed for $($migrations.Count) migrations in order."
