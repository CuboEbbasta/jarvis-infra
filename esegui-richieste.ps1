# Brina - esecutore delle richieste di Hermes (decisione dell'utente, 03/11/2026: avvio agenti con ELENCO CHIUSO).
# Hermes NON ha accesso al terminale di Windows: scrive un file .txt in DBVault\Machine\Richieste\ con UNA riga:
#     rassegna  |  posta  |  salute  |  dashboard  |  doctor  |  study <Corso>        (es. "study Programmazione")
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
    if ($r -match '^(rassegna|posta|salute|dashboard|doctor)$') { return @{ azione = $r; arg = $null } }
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
            'doctor'   { $out = & docker compose run --rm doctor 2>&1 }
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
        $stato = 'rifiutata'; $righe = @('Azione non in elenco. Ammesse: rassegna, posta, salute, dashboard, doctor, study <Corso>.'); $codice = ''
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

# ---- Lavori approvati nell'app (ADR-0010): file <data>_r<id>.richiesta.json scritti SOLO dopo l'approvazione con PIN ----
# Ogni campo si ricontrolla qui (elenco chiuso): il testo e' un DATO passato al lavoratore come argomento, mai eseguito.
# Esito in Esiti\r<id>.json (stato in_corso -> finita|errore|interrotta|rifiutata_dal_pc), letto dall'app.
$studio = Split-Path $root -Parent
$CARTELLE = @{
    app = Join-Path $root 'app'; agents = $agents
    programmazione = Join-Path $studio 'Programmazione'; sandbox = Join-Path $studio 'Sandbox-Antigravity'
}
$TIPI = @{ sviluppo = 'claude-code'; revisione = 'codex'; prototipo = 'antigravity'; ricerca = 'ricercatore'; agente = 'lavoratore-locale' }
$MAX_MINUTI = 30

function Scrivi-Esito($id, $stato, $esito, $extra = @{}) {
    $o = [ordered]@{ id = $id; stato = $stato; esito = $esito; aggiornato = (Get-Date).ToString('s') }
    foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }
    $tmp = Join-Path $esiti "r$id.json.tmp"
    [IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination (Join-Path $esiti "r$id.json") -Force
}

function Verifica-Lavoro($l) {
    # restituisce $null se valido, altrimenti il motivo del rifiuto
    if (-not ($l.id -is [int] -or $l.id -is [long]) -or $l.id -lt 1) { return 'id non valido' }
    if (-not $TIPI.ContainsKey([string]$l.tipo)) { return 'tipo non ammesso' }
    if ($TIPI[[string]$l.tipo] -ne $l.destinazione) { return 'destinazione non coerente con il tipo' }
    if ($l.privacy -notin 1, 2, 3) { return 'privacy non valida' }
    if ($l.tipo -eq 'agente') {
        if ($l.agente -notin 'rassegna', 'posta', 'salute', 'dashboard', 'study', 'doctor') { return 'agente non ammesso' }
        if ($l.agente -eq 'study' -and -not ([string]$l.corso -match '^[A-Za-z][A-Za-z0-9_-]{0,39}$')) { return 'corso non valido' }
        return $null
    }
    if ($l.privacy -eq 3) { return 'privacy 3: solo locale' }
    if ($l.privacy -eq 2 -and $l.ok_cloud -ne $true) { return 'privacy 2 senza OK' }
    $ammesse = @{ sviluppo = 'app', 'agents', 'programmazione', 'sandbox'; revisione = 'app', 'agents', 'programmazione', 'sandbox'; prototipo = @('sandbox'); ricerca = @() }[[string]$l.tipo]
    if ($ammesse.Count -eq 0) { if ($l.cartella) { return 'cartella non ammessa' } }
    elseif ([string]$l.cartella -notin $ammesse) { return 'cartella non ammessa' }
    if (-not ([string]$l.testo).Trim()) { return 'testo vuoto' }
    return $null
}

function Lancia-Job($l) {
    # ogni lavoratore in un job separato (si puo' fermare); argomenti come array: nessuna interpolazione del testo
    # PowerShell 5.1 non protegge le virgolette dentro gli argomenti dei programmi esterni: un " nel testo potrebbe chiudere
    # l'argomento e aggiungere opzioni. Si sostituiscono con virgolette tipografiche (nessuna " arriva alla riga di comando).
    $compito = ([string]$l.testo) -replace '"', [string][char]0x201D
    $prompt = "Richiesta n. $($l.id) da Brina, approvata da Mathias. Lavora solo nella cartella corrente, non fare commit ne' push, " +
              "non leggere file .env o chiavi. Alla fine scrivi in italiano un riassunto breve di cosa hai fatto.`n`nCompito:`n$compito"
    switch ($l.destinazione) {
        'claude-code' {
            $dir = $CARTELLE[[string]$l.cartella]; $set = Join-Path $PSScriptRoot 'claude-richieste.settings.json'
            return Start-Job -ArgumentList $dir, $set, $prompt -ScriptBlock { param($d, $s, $p)
                Set-Location $d; [Console]::OutputEncoding = [Text.Encoding]::UTF8
                & claude -p $p --settings $s --permission-mode acceptEdits --allowedTools Read Grep Glob Edit Write --disallowedTools Bash WebFetch WebSearch 2>&1 }
        }
        'ricercatore' {
            $dir = Join-Path $env:TEMP ("brina-ricerca-" + $l.id); New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $set = Join-Path $PSScriptRoot 'claude-richieste.settings.json'
            return Start-Job -ArgumentList $dir, $set, $prompt -ScriptBlock { param($d, $s, $p)
                Set-Location $d; [Console]::OutputEncoding = [Text.Encoding]::UTF8
                & claude -p $p --settings $s --allowedTools WebSearch WebFetch --disallowedTools Bash Edit Write Read Grep Glob 2>&1 }
        }
        'codex' {
            $a = @('-A', 'codex', '-Cartella', $CARTELLE[[string]$l.cartella], '-Privacy', [string]$l.privacy, '-Compito', $prompt)
            if ($l.privacy -eq 2) { $a += '-OkUtente' }   # l'OK per il cloud e' stato dato nell'app per questa richiesta
            return Start-Job -ArgumentList (Join-Path $PSScriptRoot 'delega.ps1'), $a -ScriptBlock { param($f, $a) & powershell -NoProfile -ExecutionPolicy Bypass -File $f @a 2>&1 }
        }
        'antigravity' {
            # privacy 1, nessun file scrivibile: risposta in sola lettura; giorni riservati e tetto giornaliero li applica delega.ps1
            $a = @('-A', 'antigravity', '-Cartella', $CARTELLE['sandbox'], '-Privacy', '1', '-Compito', $prompt)
            return Start-Job -ArgumentList (Join-Path $PSScriptRoot 'delega.ps1'), $a -ScriptBlock { param($f, $a) & powershell -NoProfile -ExecutionPolicy Bypass -File $f @a 2>&1 }
        }
    }
    return $null
}

function Elabora-Lavoro([IO.FileInfo]$f) {
    $inizio = Get-Date
    try { $l = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $l = $null }
    $id = if ($l -and ($l.id -is [int] -or $l.id -is [long])) { $l.id } else { 0 }
    if ($id -eq 0 -and $f.Name -match '_r(\d{1,12})\.richiesta\.json$') { $id = [long]$Matches[1] }   # file rovinato: l'esito va comunque all'app
    $motivo = if ($l) { Verifica-Lavoro $l } else { 'file non leggibile' }
    $dest = Join-Path $fatte $f.Name
    if ($motivo) {
        if ($id -gt 0) { Scrivi-Esito $id 'rifiutata_dal_pc' "Rifiutata dall'esecutore: $motivo." }
        Move-Item -LiteralPath $f.FullName -Destination $dest -Force
        Invia-Avviso ([char]::ConvertFromUtf32(0x26D4) + " Richiesta n. ${id}: rifiutata dal PC ($motivo).") | Out-Null
        return
    }
    Move-Item -LiteralPath $f.FullName -Destination $dest -Force     # presa in carico: non riparte due volte
    $stop = Join-Path $req "r$id.stop"
    Scrivi-Esito $id 'in_corso' $null @{ destinazione = $l.destinazione }
    $stato = 'errore'; $righe = @()
    if ($l.tipo -eq 'agente') {
        $a = @{ azione = [string]$l.agente; arg = $(if ($l.agente -eq 'study') { [string]$l.corso } else { $null }) }
        $r = Esegui $a; $righe = $r.righe; $stato = if ($r.codice -eq 0) { 'finita' } else { 'errore' }
    } else {
        $job = Lancia-Job $l
        if (-not $job) { $righe = @('Destinazione non gestita.') }
        else {
            $fine = $inizio.AddMinutes($MAX_MINUTI)
            while ($job.State -eq 'Running' -and (Get-Date) -lt $fine -and -not (Test-Path $stop)) { Start-Sleep -Seconds 5 }
            if (Test-Path $stop) { Stop-Job $job; $stato = 'interrotta'; $righe = @('Interrotta da Mathias.') }
            elseif ($job.State -eq 'Running') { Stop-Job $job; $stato = 'errore'; $righe = @("Fermata dopo $MAX_MINUTI minuti.") }
            else { $stato = if ($job.State -eq 'Completed') { 'finita' } else { 'errore' } }
            $righe = @($righe) + @(Receive-Job $job -ErrorAction SilentlyContinue | ForEach-Object { "$_" } |
                Where-Object { $_ -notmatch '^(Denying Bash also turns off|Permission deny rule \()' } | Select-Object -Last 120)
            Remove-Job $job -Force -ErrorAction SilentlyContinue
            if ($stato -eq 'finita' -and ($righe -join "`n") -match 'RIFIUTATO:') { $stato = 'errore' }   # delega.ps1 ha rifiutato
        }
    }
    Remove-Item $stop -ErrorAction SilentlyContinue
    $testo = ($righe -join "`n"); if ($testo.Length -gt 6000) { $testo = $testo.Substring($testo.Length - 6000) }
    $min = [math]::Round(((Get-Date) - $inizio).TotalMinutes, 1)
    Scrivi-Esito $id $stato $testo @{ durata_min = $min; destinazione = $l.destinazione }
    $icona = @{ finita = '✅'; errore = '❌'; interrotta = '⏹️' }[$stato]
    Invia-Avviso "$icona Richiesta n. $id ($($l.destinazione)): $stato in $min min. Dettagli nell'app, pagina Richieste." | Out-Null
}

do {
    Get-ChildItem -Path $req -Filter *.txt -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddSeconds(-5) } |
        Sort-Object LastWriteTime | ForEach-Object {   # 5 s di attesa: il file potrebbe essere ancora in scrittura
        try { Elabora $_ } catch { Write-Host "Errore su $($_.Exception.Message)" }
    }
    Get-ChildItem -Path $req -Filter *.richiesta.json -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddSeconds(-5) } |
        Sort-Object LastWriteTime | ForEach-Object {
        try { Elabora-Lavoro $_ } catch { Write-Host "Errore su $($_.Exception.Message)" }
    }
    if ($Ciclo) { Start-Sleep -Seconds 30 }
} while ($Ciclo)
