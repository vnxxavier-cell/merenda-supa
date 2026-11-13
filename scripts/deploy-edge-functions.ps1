[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$supabase = Get-Command supabase -ErrorAction SilentlyContinue
if (-not $supabase) {
  throw 'Supabase CLI was not found. Install it before deploying Edge Functions.'
}

# SUPABASE_URL, SUPABASE_ANON_KEY e SUPABASE_SERVICE_ROLE_KEY são injetadas
# automaticamente pela plataforma Supabase em toda Edge Function — não podem
# (e não precisam ser) definidas como secrets pelo CLI (prefixo SUPABASE_ é reservado).

$functions = @(
  'legacy-login',
  'claim-google-login',
  'session-status',
  'admin-users'
)

foreach ($name in $functions) {
  & $supabase.Source functions deploy $name --no-verify-jwt
  if ($LASTEXITCODE -ne 0) {
    throw "Deployment of $name failed."
  }
}

"Deployed $($functions.Count) Edge Functions with internal bearer verification."
