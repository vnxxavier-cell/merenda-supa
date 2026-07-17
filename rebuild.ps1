$MdPath = "C:\Users\SEEMG\Pictures\PROJETO SUPA2\Educacao-Basica.md"
$OutPath = "C:\Users\SEEMG\Pictures\PROJETO SUPA2\cardapios_data.js"

$bytes = [System.IO.File]::ReadAllBytes($MdPath)
$md = [System.Text.Encoding]::UTF8.GetString($bytes)
$NL = "`r`n"

Write-Host "Splitting..."
$sections = [regex]::Split($md, '(?m)^(?:##\s*)?(?=Card.pio\s+\d+\s*[^\w\s])')
$sections = $sections | Where-Object { $_ -match 'Modo de Preparar' -and $_ -match 'Ingredientes' -and $_ -match '(?m)^Tipo de prepara' }

$seenIds = @{}
foreach ($sec in $sections) {
    if ($sec -match 'Card.pio\s+(\d+)') { $seenIds[[int]$Matches[1]] = $sec }
}
Write-Host ("Sections: $($seenIds.Count)")

$groupMap = @{}
1..14 | % { $groupMap[$_] = 1 }
15..47 | % { $groupMap[$_] = 2 }
48..56 | % { $groupMap[$_] = 3 }
57..72 | % { $groupMap[$_] = 4 }
73..85 | % { $groupMap[$_] = 5 }
86..90 | % { $groupMap[$_] = 6 }
91..98 | % { $groupMap[$_] = 7 }

$js = "const CD = [" + $NL
$totalIngs = 0

foreach ($id in ($seenIds.Keys | Sort-Object)) {
    $sec = $seenIds[$id]
    $lines = $sec -split '\r?\n'
    
    $t = $lines | Where-Object { $_ -match '^[#]*\s*Card.pio\s+\d+\s*[^\w\s]' } | Select-Object -First 1
    if (-not $t) { continue }
    $rest = $t -replace '^[#]*\s*Card.pio\s+\d+\s*', ''; $rest = $rest.Trim() -replace '^[^\w\s]+\s*', ''
    $nome = ($rest.Trim() -replace "'", "\'")
    
    $tipo = 'lanche'
    foreach ($l in $lines) { if ($l -match 'Tipo de prepara') { $tm = [regex]::Match($l, 'Tipo de prepara.+\s*[–\-]\s*(.+)$'); if($tm.Success){$tipo=($tm.Groups[1].Value.Trim()-replace "'","\'")} } }
    
    $gid = if ($groupMap.ContainsKey($id)) { $groupMap[$id] } else { 2 }
    
    $ingStart = -1; $modoStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'Ingredientes') { $ingStart = $i }
        if ($lines[$i] -match 'Modo de Preparar') { $modoStart = $i; break }
    }
    
    $ings = @()
    if ($ingStart -gt 0 -and $modoStart -gt $ingStart) {
        $raw = $lines[($ingStart+1)..($modoStart-1)]
        $body = @()
        foreach ($l in $raw) {
            $lt = $l.Trim()
            if ($lt -match '^[#]*\s*Fundamental' -or $lt -match '^\d+ a \d+ anos' -or $lt -match '^M.dio' -or $lt.Length -eq 0) { continue }
            $body += $lt
        }
        $i = 0
        while ($i -lt $body.Count) {
            $line = $body[$i] -replace '^[#]*\s*', ''
            $nc = 0; foreach ($p in ($line -split ' ')) { if ($p -match '^\d') { $nc++ }; if ($nc -ge 4) { break } }
            if ($nc -ge 4) {
                $parts = @(); $fn = $false
                foreach ($p in ($line -split ' ')) { if ($p -match '^\d') { $fn=$true; break }; if (-not $fn) { $parts+=$p } }
                $in = (($parts -join ' ').Trim() -replace "'", "\'")
                $vals = @()
                foreach ($p in ($line -split ' ')) {
                    if ($p -match '^(\d+)[.,](\d*)') { $vals += ($Matches[1]+'.'+$Matches[2]) }
                    elseif ($p -match '^(\d+)') { $vals += $Matches[1] }
                    if ($vals.Count -ge 4) { break }
                }
                while ($vals.Count -lt 4) { $vals += '0' }
                $ings += $in; $ings += $vals[0]; $ings += $vals[1]; $ings += $vals[2]; $ings += $vals[3]
                $totalIngs++; $i++
            } else {
                $in = ($line -replace '^- ', '').Trim()
                if ($i + 1 -lt $body.Count) {
                    $nx = ($body[$i+1] -replace '^[#]*\s*', '')
                    $nc2 = 0; foreach ($p in ($nx -split ' ')) { if ($p -match '^\d') { $nc2++ }; if ($nc2 -ge 4) { break } }
                    if ($nc2 -ge 4) {
                        $vals = @()
                        foreach ($p in ($nx -split ' ')) {
                            if ($p -match '^(\d+)[.,](\d*)') { $vals += ($Matches[1]+'.'+$Matches[2]) }
                            elseif ($p -match '^(\d+)') { $vals += $Matches[1] }
                            if ($vals.Count -ge 4) { break }
                        }
                        while ($vals.Count -lt 4) { $vals += '0' }
                        $ings += ($in -replace "'","\'"); $ings += $vals[0]; $ings += $vals[1]; $ings += $vals[2]; $ings += $vals[3]
                        $totalIngs++; $i += 2; continue
                    }
                }
                $i++
            }
        }
    }
    
    $modo = ''
    if ($modoStart -gt 0) {
        $ml = @()
        for ($i = $modoStart+1; $i -lt $lines.Count; $i++) {
            $l = $lines[$i].Trim()
            if ($l -match '^##?\s*Sugest' -or $l -match '^##?\s*\d+$' -or $l -match 'Informa' -or $l -match '^Card.pio\s+\d+' -or $l -match '^##?\s*GRUPO') { break }
            if ($l.Length -gt 0) { $ml += ($l -replace '^- ', '') }
        }
        $modo = ($ml -join ' ') -replace '\s+', ' '
        $modo = $modo -replace "'", "\'"
    }
    
    $sugest = ''
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^[#]*\s*Sugest') {
            $sl = @()
            for ($j = $i+1; $j -lt $lines.Count; $j++) {
                $l = $lines[$j].Trim()
                if ($l -match '^##?\s*\d+$' -or $l -match 'Informa' -or $l -match '^Card.pio\s+\d+' -or $l -match '^##?\s*GRUPO') { break }
                if ($l.Length -gt 0) { $sl += ($l -replace '^- ', '') }
            }
            $sugest = ($sl -join ' ') -replace '\s+', ' '
            $sugest = $sugest -replace "'", "\'"
            break
        }
    }
    
    if ($ings.Count -gt 0) {
        $ingsFmt = @()
        for ($idx = 0; $idx -lt $ings.Count; $idx += 5) {
            $ingsFmt += "'$($ings[$idx])'"
            for ($j = 1; $j -le 4; $j++) { $ingsFmt += $ings[$idx + $j] }
        }
        $js += "  [$id,'$nome','$tipo',$gid,[" + ($ingsFmt -join ',') + "],'$modo','$sugest']," + $NL
    }
}

$js += "];" + $NL
[System.IO.File]::WriteAllText($OutPath, $js, [System.Text.UTF8Encoding]::new($false))
Write-Host "Done: $($seenIds.Count) cardapios, $totalIngs ingredients"
