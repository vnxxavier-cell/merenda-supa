[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$DumpPath,

  [string]$ExpectedSha256
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DumpPath)) {
  throw 'Backup dump file was not found.'
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $DumpPath).Hash.ToLowerInvariant()
if ($ExpectedSha256 -and $hash -ne $ExpectedSha256.Trim().ToLowerInvariant()) {
  throw 'Backup checksum does not match the expected SHA256.'
}

"Backup checksum verified: $hash"
