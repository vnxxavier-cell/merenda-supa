[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BackupDumpPath,

  [string]$BackupSha256
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot

$supabase = Get-Command supabase -ErrorAction SilentlyContinue
if (-not $supabase) {
  throw 'Supabase CLI was not found. Install it before applying migrations.'
}

if (-not (Test-Path -LiteralPath $BackupDumpPath)) {
  throw 'Backup dump file was not found. Create a verified backup first.'
}

& "$PSScriptRoot\verify-supabase-backup.ps1" `
  -DumpPath $BackupDumpPath `
  -ExpectedSha256 $BackupSha256

& (Join-Path $root 'tests\contract-check.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Contract check failed; aborting migration application.' }
& (Join-Path $root 'tests\sql-static-check.ps1')
if ($LASTEXITCODE -ne 0) { throw 'SQL static check failed; aborting migration application.' }

& $supabase.Source projects list | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw 'Unable to list Supabase projects. Run "supabase login" and "supabase link" first.'
}

$finalMigration = Join-Path $root 'supabase\migrations\20260903990000_auth_rls_cutover.sql'
$finalBackup = "$finalMigration.hold"
if (Test-Path -LiteralPath $finalBackup) {
  throw "Refusing to apply while the final cutover hold file already exists: $finalBackup"
}

try {
  # Apply only the additive foundation migrations by temporarily holding the
  # final guarded cutover migration back. It is restored afterwards and can be
  # applied separately once the admin approves the cutover.
  Move-Item -LiteralPath $finalMigration -Destination $finalBackup
  & $supabase.Source migration up --linked
  if ($LASTEXITCODE -ne 0) { throw 'Supabase migration up failed.' }
} finally {
  if (Test-Path -LiteralPath $finalBackup) {
    Move-Item -LiteralPath $finalBackup -Destination $finalMigration
  }
}

"Foundation migrations 001-006 applied. Final cutover migration remains pending."
