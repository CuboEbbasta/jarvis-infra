# Jarvis - verifica INDIPENDENTE delle regole di sicurezza (non la fa un agente: e' uno script fisso).
# Controlla che i confini decisi non siano stati allentati per errore: segreti fuori da Git, porte solo locali,
# vault montato in sola lettura dal server MCP, regole di divieto presenti, task senza finestre.
# Non legge MAI il contenuto di .env o chiavi. Scrive Machine\Status\policy.md; con -Avvisa manda Telegram solo se qualcosa e' cambiato in peggio.
# Uso: powershell -ExecutionPolicy Bypass -File .\verifica-policy.ps1 [-Avvisa]
param([switch]$Avvisa)
$ErrorActionPreference = 'Continue'
$jarvis = Split-Path $PSScriptRoot -Parent
$righe = New-Object System.Collections.ArrayList
$ko = 0
function Controllo($nome, [bool]$ok, $dett) { if (-not $ok) { $script:ko++ }; [void]$righe.Add("| $(if ($ok) { '✅' } else { '❌' }) | $nome | $dett |") }

# 1) segreti: ignorati da Git e mai tracciati
foreach ($p in @(@('infra', 'infra/.env'), @('agents', 'agents/.env'), @('osiris', 'osiris/osiris.env'))) {
  $f = Join-Path $jarvis ($p[1] -replace '/', '\')
  if (Test-Path $f) { $ign = (git -C $jarvis check-ignore $p[1] 2>$null); Controllo "$($p[1]) ignorato da Git" ([bool]$ign) 'git check-ignore' }
}
$tracciati = @(); foreach ($r in 'agents', 'infra', 'DBVault', '.') {
  $d = if ($r -eq '.') { $jarvis } else { Join-Path $jarvis $r }
  if (Test-Path (Join-Path $d '.git')) { $tracciati += git -C $d ls-files 2>$null | Where-Object { $_ -match '(^|/)\.env($|\.)|\.key$|\.pem$|osiris\.env$|callmebot\.txt$|ical\.txt$|client_secret' -and $_ -notmatch 'example|esempio' } }
}
Controllo 'Nessun .env/chiave tracciato da Git' ($tracciati.Count -eq 0) $(if ($tracciati.Count) { "TRACCIATI: $($tracciati -join ', ')" } else { 'agents, infra, DBVault, config' })

# 2) porte Docker: pubblicate solo su 127.0.0.1
$porte = @(docker ps --format '{{.Names}}|{{.Ports}}' 2>$null)
$aperte = @($porte | Where-Object { $_ -match '(^|[ ,|])(0\.0\.0\.0|\[::\]|:::)[:\d]' -and $_ -match '->' })
Controllo 'Porte Docker solo su 127.0.0.1' ($aperte.Count -eq 0) $(if ($aperte.Count) { "APERTE: " + (($aperte | ForEach-Object { ($_ -split '\|')[0] }) -join ', ') } else { "$($porte.Count) container controllati" })

# 3) server MCP: vault in sola lettura, filesystem in sola lettura
$mcp = docker inspect jarvis-agents-mcp-1 2>$null | ConvertFrom-Json
if ($mcp) {
  $vaultRw = @($mcp[0].Mounts | Where-Object { $_.Destination -eq '/vault' -and $_.RW }).Count
  Controllo 'MCP: vault montato in sola lettura' ($vaultRw -eq 0) '/vault ro'
  Controllo 'MCP: filesystem del container in sola lettura' ([bool]$mcp[0].HostConfig.ReadonlyRootfs) 'read_only'
  $pub = $mcp[0].NetworkSettings.Ports.'3020/tcp'
  Controllo 'MCP: pubblicato solo su 127.0.0.1' (-not ($pub | Where-Object { $_.HostIp -ne '127.0.0.1' })) 'porta 3020'
} else { [void]$righe.Add('| ➖ | Server MCP | non in esecuzione (non controllato) |') }

# 4) regole di divieto di lettura presenti nei settings di Claude Code (controllo sulle STRINGHE, non sui file privati)
foreach ($s in @("$jarvis\.claude\settings.json", "$jarvis\DBVault\.claude\settings.json")) {
  if (Test-Path $s) {
    $t = Get-Content $s -Raw -Encoding UTF8
    foreach ($req in @('.env', 'Human/Daily', 'Contesto/Email', 'Contesto/Calendario')) {
      Controllo "$(if ($s -like '*DBVault*') { 'DBVault' } else { 'Jarvis' }): divieto di lettura su $req" ($t -match [regex]::Escape($req)) 'deny presente'
    }
  }
}

# 5) attivita' pianificate: senza finestre e con la cartella giusta
Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | Where-Object TaskName -like 'Jarvis*' | ForEach-Object {
  $a = $_.Actions[0]; $nasc = ($a.Execute -match 'wscript') -or ($a.Arguments -match '-WindowStyle Hidden')
  Controllo "Attivita' '$($_.TaskName)' attiva" ($_.State -ne 'Disabled') "$($_.State)$(if ($a.Execute -notmatch 'wscript') { ' (finestra visibile un istante)' })"
}

# 6) Codex: il profilo protetto di Jarvis esiste
Controllo 'Codex: profilo ~\.codex-jarvis presente' (Test-Path "$env:USERPROFILE\.codex-jarvis") 'config separata dal profilo normale'

$ora = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$md = @('---', 'type: status', 'agent: verifica-policy', "updated: $ora", "problemi: $ko", '---', '# Verifica delle regole di sicurezza', '',
        "Eseguita il $ora da `infra/verifica-policy.ps1` (script fisso, non un agente). ❌ = confine allentato o non verificabile.", '',
        '| | Controllo | Dettaglio |', '|---|---|---|') + $righe
$out = Join-Path $jarvis 'DBVault\Machine\Status\policy.md'
$prima = if (Test-Path $out) { ((Get-Content $out -Encoding UTF8 -TotalCount 6 | Where-Object { $_ -match '^problemi:' }) -replace 'problemi:\s*', '') } else { '0' }
Set-Content $out $md -Encoding UTF8
Write-Host "Verifica policy: $ko problemi su $($righe.Count) controlli -> $out"
if ($Avvisa -and $ko -gt 0 -and "$ko" -ne "$prima") {
  . (Join-Path $PSScriptRoot 'avvisa-telegram.ps1')
  Invia-Avviso "Verifica sicurezza Jarvis: $ko controlli falliti. Dettagli: Machine/Status/policy.md" | Out-Null
}
