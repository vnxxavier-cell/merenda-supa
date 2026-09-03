[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$OutputDirectory,

  [string]$DatabaseUrl = $env:SUPABASE_DB_URL
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
  throw 'Set SUPABASE_DB_URL or pass -DatabaseUrl. Do not put it in Git.'
}

$pgDump = Get-Command pg_dump -ErrorAction SilentlyContinue
if (-not $pgDump) {
  throw 'pg_dump was not found. Install PostgreSQL client tools before creating a backup.'
}

$target = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not (Test-Path -LiteralPath $target)) {
  New-Item -ItemType Directory -Path $target -Force | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dumpPath = Join-Path $target "cardapiocerto-production-$stamp.dump"
$manifestPath = Join-Path $target "cardapiocerto-production-$stamp.manifest.json"
$hashPath = "$dumpPath.sha256"

if ((Test-Path -LiteralPath $dumpPath) -or (Test-Path -LiteralPath $manifestPath)) {
  throw 'Refusing to overwrite an existing backup artifact.'
}

& $pgDump.Source `
  --dbname=$DatabaseUrl `
  --format=custom `
  --no-owner `
  --no-privileges `
  --file=$dumpPath

if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dumpPath)) {
  throw "pg_dump failed with exit code $LASTEXITCODE."
}

$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $dumpPath
$hashLine = "$($hash.Hash.ToLowerInvariant()) *$([System.IO.Path]::GetFileName($dumpPath))"
[System.IO.File]::WriteAllText($hashPath, $hashLine + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

$manifest = [ordered]@{
  created_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  dump_path = $dumpPath
  sha256_path = $hashPath
  sha256 = $hash.Hash.ToLowerInvariant()
  bytes = (Get-Item -LiteralPath $dumpPath).Length
  pg_dump = (& $pgDump.Source --version)
  purpose = 'Pre-migration recovery backup. Contains sensitive production data.'
}
$json = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

"Backup created: $dumpPath"
"Manifest: $manifestPath"
"SHA256: $($hash.Hash.ToLowerInvariant())"
