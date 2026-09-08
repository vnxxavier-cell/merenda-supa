$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$requiredFiles = @(
  'app_v2.js',
  'app_v2_bridge.js',
  'supabase/config.toml',
  'supabase/migrations/20260903000100_legacy_snapshots.sql',
  'supabase/migrations/20260903000200_identity_and_ownership.sql',
  'supabase/migrations/20260903000300_domain_foundation.sql',
  'supabase/migrations/20260903000400_server_first_foundation.sql',
  'supabase/migrations/20260903000500_admin_import_and_integrity.sql',
  'supabase/migrations/20260903000600_legacy_domain_import.sql',
  'supabase/migrations/20260903990000_auth_rls_cutover.sql',
  'supabase/functions/legacy-login/index.ts',
  'supabase/functions/claim-google-login/index.ts',
  'supabase/functions/session-status/index.ts',
  'supabase/functions/admin-users/index.ts'
)

foreach ($relativePath in $requiredFiles) {
  $path = Join-Path $root $relativePath
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Required migration artifact is missing: $relativePath"
  }
}

$sql = Get-ChildItem -LiteralPath (Join-Path $root 'supabase/migrations') -Filter '*.sql' |
  Sort-Object Name |
  ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }
$sqlText = $sql -join "`n"

$requiredSqlFunctions = @(
  'edge_login_resolve',
  'edge_legacy_login_verify',
  'edge_legacy_login_complete',
  'edge_session_activate',
  'edge_session_authorize',
  'edge_session_revoke',
  'edge_claim_google_login',
  'app_v2_capabilities',
  'app_v2_session_context',
  'app_v2_load_school_state',
  'app_v2_save_school_state',
  'app_v2_capture_legacy_browser_state',
  'edge_admin_profile_get',
  'edge_admin_profiles_list',
  'edge_admin_profile_create',
  'edge_admin_profile_update',
  'edge_admin_profile_deactivate',
  'edge_admin_google_requests_list',
  'edge_admin_google_request_approve',
  'edge_admin_google_request_reject',
  'edge_frontend_v2_verify',
  'admin_import_legacy_domain',
  'edge_auth_cutover_readiness',
  'edge_auth_cutover_approve'
)

foreach ($functionName in $requiredSqlFunctions) {
  if ($sqlText -notmatch [regex]::Escape($functionName)) {
    throw "Required SQL function contract is missing: $functionName"
  }
}

$clientText = [System.IO.File]::ReadAllText((Join-Path $root 'app_v2.js'))
$bridgeText = [System.IO.File]::ReadAllText((Join-Path $root 'app_v2_bridge.js'))
if ($clientText -match 'forceFullSync|crypto\.subtle|SHA-256') {
  throw 'The V2 client must not include legacy full-sync or browser SHA-256 authentication.'
}
if ($bridgeText -match 'forceFullSync|crypto\.subtle|SHA-256') {
  throw 'The V2 bridge must not include legacy full-sync or browser SHA-256 authentication.'
}

$legacyLogin = [System.IO.File]::ReadAllText((Join-Path $root 'supabase/functions/legacy-login/index.ts'))
if ($legacyLogin -notmatch 'edge_login_resolve' -or $legacyLogin -notmatch 'edge_legacy_login_verify') {
  throw 'legacy-login does not implement both migrated and first-login paths.'
}
if ($legacyLogin -notmatch 'access_token' -or $legacyLogin -notmatch 'refresh_token') {
  throw 'legacy-login response must expose Supabase session token names expected by AppV2.'
}

if ($clientText -notmatch 'googleRequests' -or $clientText -notmatch 'approveGoogle' -or
    $clientText -notmatch 'rejectGoogle' -or $clientText -notmatch 'verifyFrontendV2' -or
    $clientText -notmatch 'google-pending') {
  throw 'AppV2 does not expose the Google approval and pending contracts.'
}

$claimGoogle = [System.IO.File]::ReadAllText((Join-Path $root 'supabase/functions/claim-google-login/index.ts'))
if ($claimGoogle -notmatch 'pending' -or $claimGoogle -notmatch 'approved') {
  throw 'claim-google-login does not implement the pending/approved flow.'
}

$index = [System.IO.File]::ReadAllText((Join-Path $root 'index.html'))
if ($index -notmatch 'overlay-google-admin' -or $index -notmatch 'aprovarGoogleRequest' -or
    $index -notmatch 'salvarUsuarioForm\(\)') {
  throw 'index.html does not expose the admin Google approval UI or the explicit user save button.'
}

$configPath = Join-Path $root 'supabase/config.toml'
$tokens = $null
$configParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $root 'scripts/backup-supabase.ps1'),
  [ref]$tokens,
  [ref]$configParseErrors
) | Out-Null
if ($configParseErrors.Count -gt 0) {
  throw 'backup-supabase.ps1 has PowerShell parse errors.'
}

"Contract check passed: $($requiredFiles.Count) required files and $($requiredSqlFunctions.Count) SQL contracts verified."
