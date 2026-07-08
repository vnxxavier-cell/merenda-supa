$path = "C:\Users\SEEMG\Pictures\PROJETO SUPA2\index.html"
$bytes = [System.IO.File]::ReadAllBytes($path)
$text = [System.Text.Encoding]::UTF8.GetString($bytes)

# Find the old corrupt data
$marker = '"79 - Leite Achocolatado e P\u00e3o":['
$idx = $text.IndexOf($marker)
if ($idx -lt 0) {
    Write-Host "Marker not found with unicode escape. Trying raw..."
    # Try with raw UTF-8 bytes for special chars
    $rawMarker = @(34, 55, 57, 32, 45, 32, 76, 101, 105, 116, 101, 32, 65, 99, 104, 111, 99, 111, 108, 97, 116, 97, 100, 111, 32, 101, 32, 80, 195, 163, 111, 34, 58, 91)
    $rawMarkerStr = [System.Text.Encoding]::UTF8.GetString($rawMarker)
    $idx = $text.IndexOf($rawMarkerStr)
}
if ($idx -lt 0) { Write-Host "NOT FOUND"; exit 1 }
Write-Host ("Found at index: " + $idx)

# Find the end of this entry - look for "]}," after the marker
$searchStart = $idx + 40
$endMarker = $text.IndexOf(']},"', $searchStart)
if ($endMarker -lt 0) { Write-Host "End marker not found"; exit 1 }

$oldEntry = $text.Substring($idx, $endMarker - $idx + 3)
Write-Host ("Old entry length: " + $oldEntry.Length)
Write-Host ("Old: " + $oldEntry.Substring(0, [Math]::Min(200, $oldEntry.Length)))

# Build the new entry
$newEntry = '"79 - Leite Achocolatado e P\u00e3o":[{"i":"ACHOCOLATADO EM P\u00d3","g":6.5,"f1":4.5,"f2":6.5,"medio":7.5,"eja":6.5},{"i":"LEITE INTEGRAL","g":230,"f1":160,"f2":230,"medio":260,"eja":230},{"i":"MA\u00c7\u00c3 / FRUTA DA ESTA\u00c7\u00c3O","g":90,"f1":65,"f2":90,"medio":120,"eja":90},{"i":"MARGARINA","g":5,"f1":3,"f2":5,"medio":5,"eja":5},{"i":"P\u00c3O FRANC\u00caS","g":75,"f1":50,"f2":75,"medio":75,"eja":75}],'
# Also try without escapes
$newEntry2 = '"79 - Leite Achocolatado e Pão":[{"i":"ACHOCOLATADO EM PÓ","g":6.5,"f1":4.5,"f2":6.5,"medio":7.5,"eja":6.5},{"i":"LEITE INTEGRAL","g":230,"f1":160,"f2":230,"medio":260,"eja":230},{"i":"MAÇÃ / FRUTA DA ESTAÇÃO","g":90,"f1":65,"f2":90,"medio":120,"eja":90},{"i":"MARGARINA","g":5,"f1":3,"f2":5,"medio":5,"eja":5},{"i":"PÃO FRANCÊS","g":75,"f1":50,"f2":75,"medio":75,"eja":75}],'

$newText = $text.Replace($oldEntry, $newEntry2)
if ($newText -eq $text) { Write-Host "Replace had no effect!"; exit 1 }

[System.IO.File]::WriteAllText($path, $newText, [System.Text.UTF8Encoding]::new($false))
Write-Host "Done - file updated"
