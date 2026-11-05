# Jarvis - esecutore delle richieste di Hermes (decisione dell'utente, 03/11/2026: avvio agenti con ELENCO CHIUSO).
# Hermes NON ha accesso al terminale di Windows: scrive un file .txt in DBVault\Machine\Richieste\ con UNA riga:
#     rassegna  |  posta  |  salute  |  study <Corso>        (es. "study Programmazione")
# Questo script (sul PC) esegue solo queste azioni, scrive l'esito in Machine\Richieste\Esiti\ e avvisa su Telegram.
# Qualsiasi altra riga viene rifiutata. Stessa azione al massimo una volta ogni 15 minuti.
# Prova una volta:        powershell -ExecutionPolicy Bypass -File .\esegui-richieste.ps1
# Sempre attivo (accesso): powershell -ExecutionPolicy Bypass -File .\esegui-richieste.ps1 -Schedule
# Rimuovere: Unregister-ScheduledTask -TaskName "Jarvis Richieste" -Confirm:$false
param([switch]$Schedule, [switch]$Ciclo)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}   # emoji leggibili negli esiti
if ($Schedule) {
    $act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Ciclo"
    $trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
           -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName "Jarvis Richieste" -Action $act -Trigger $trg -Settings $set -Description "Esegue le richieste di Hermes (elenco chiuso)" -Force | Out-Null
    Start-ScheduledTask -TaskName "Jarvis Richieste"
    Write-Host "Attività 'Jarvis Richieste' creata e avviata: controlla Machine\Richieste ogni 30 secondi."
    return
}

$root   = Split-Path $PSScriptRoot -Parent
$agents = Join-Path $root 'agents'
$req    = Join-Path $root 'DBVault\Machine\Richieste'
$esiti  = Join-Path $req 'Esiti'
$fatte  = Join-Path $req 'Fatte'
New-Item -ItemType Directory -Force -Path $req, $esiti, $fatte | Out-Null
. (Join-Path $PSScriptRoot 'avvisa-telegram.ps1')
$ultimo = @{}

function Interpreta([string]$riga) {
    $r = ($riga -replace '^﻿', '').Trim().ToLower()
    if ($r -match '^(rassegna|posta|salute|dashboard)$') { return @{ azione = $r; arg = $null } }
    $m = [regex]::Match(($riga -replace '^﻿', '').Trim(), '^(?i:study)\s+([A-Za-z][A-Za-z0-9_-]{0,39})$')
    if ($m.Success) { return @{ azione = 'study'; arg = $m.Groups[1].Value } }
    return $null
}

function Esegui($a) {
    Push-Location $agents
    try {
        switch ($a.azione) {
            'rassegna' { $out = & docker compose run --rm rassegna 2>&1 }
            'posta'    { $out = & docker compose run --rm posta 2>&1 }
            'study'    { $out = & docker compose run --rm study --course $a.arg 2>&1 }
            'salute'   { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'controllo-salute.ps1') 2>&1 }
            'dashboard' { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'genera-dashboard.ps1') 2>&1 }
        }
        return @{ codice = $LASTEXITCODE; righe = @($out | ForEach-Object { "$_" } | Select-Object -Last 15) }
    } finally { Pop-Location }
}

function Elabora([IO.FileInfo]$f) {
    $nome  = ($f.BaseName -replace '[^A-Za-z0-9_-]', '_')
    if ($nome.Length -gt 60) { $nome = $nome.Substring(0, 60) }
    $nome  = "$(Get-Date -Format 'yyyy-MM-dd_HHmmss')_$nome"
    $prima = (Get-Content $f.FullName -Encoding UTF8 -TotalCount 1)
    $a     = if ($prima) { Interpreta $prima } else { $null }
    $inizio = Get-Date
    $chiave = if ($a) { "$($a.azione) $($a.arg)".Trim() } else { '' }
    if (-not $a) {
        $stato = 'rifiutata'; $righe = @('Azione non in elenco. Ammesse: rassegna, posta, salute, dashboard, study <Corso>.'); $codice = ''
    } elseif ($ultimo.ContainsKey($chiave) -and ($inizio - $ultimo[$chiave]).TotalMinutes -lt 15) {
        $stato = 'saltata'; $righe = @("'$chiave' già eseguita meno di 15 minuti fa."); $codice = ''
    } else {
        $ultimo[$chiave] = $inizio
        # stato "in corso" visibile alla dashboard (Machine/Status/richiesta-in-corso.json): solo azione e ora d'inizio
        $inCorso = Join-Path $root 'DBVault\Machine\Status\richiesta-in-corso.json'
        try { Set-Content $inCorso (@{ azione = $chiave; inizio = $inizio.ToString('s') } | ConvertTo-Json -Compress) -Encoding UTF8 } catch {}
        try { $r = Esegui $a } finally { Remove-Item $inCorso -ErrorAction SilentlyContinue }
        $codice = $r.codice; $righe = $r.righe
        $stato = if ($codice -eq 0) { 'ok' } else { 'errore' }
    }
    $min = [math]::Round(((Get-Date) - $inizio).TotalMinutes, 1)
    $testo = @('---', 'type: esito-richiesta', "azione: `"$chiave`"", "stato: $stato", "inizio: $($inizio.ToString('s'))",
               "durata_min: $min", "codice_uscita: $codice", '---', "# Richiesta: $(if ($chiave) { $chiave } else { '(non valida)' }) — $stato", '', '```') + $righe + @('```')
    Set-Content -Path (Join-Path $esiti "$nome.md") -Value $testo -Encoding UTF8
    Move-Item -LiteralPath $f.FullName -Destination (Join-Path $fatte "$nome.txt")
    $icona = @{ ok = '✅'; errore = '❌'; rifiutata = '⛔'; saltata = '⏭️' }[$stato]
    Invia-Avviso "$icona Richiesta '$(if ($chiave) { $chiave } else { 'non valida' })': $stato ($min min). Esito: Machine/Richieste/Esiti/$nome.md" | Out-Null
}

do {
    Get-ChildItem -Path $req -Filter *.txt -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddSeconds(-5) } |
        Sort-Object LastWriteTime | ForEach-Object {   # 5 s di attesa: il file potrebbe essere ancora in scrittura
        try { Elabora $_ } catch { Write-Host "Errore su $($_.Exception.Message)" }
    }
    if ($Ciclo) { Start-Sleep -Seconds 30 }
} while ($Ciclo)
