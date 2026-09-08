[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$supabase = Get-Command supabase -ErrorAction SilentlyContinue
if (-not $supabase) {
  throw 'Supabase CLI was not found. Install it before deploying Edge Functions.'
}

$functions = @(
  'legacy-login',
  'claim-google-login',
  'session-status',
  'admin-users'
)

$requiredSecrets = @('SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY')
$missingSecrets = @()

$existing = & $supabase.Source secrets list 2>$null
foreach ($secret in $requiredSecrets) {
  if ($existing -notmatch [regex]::Escape($secret)) {
    $missingSecrets += $secret
  }
}

if ($missingSecrets.Count -gt 0) {
  throw ('Missing Edge Function secrets: ' + ($missingSecrets -join ', ') + '. Set them with "supabase secrets set" before deploying. Never commit them.')
}

foreach ($name in $functions) {
  & $supabase.Source functions deploy $name --no-verify-jwt
  if ($LASTEXITCODE -ne 0) {
    throw "Deployment of $name failed."
  }
}

"Deployed $($functions.Count) Edge Functions with internal bearer verification."
