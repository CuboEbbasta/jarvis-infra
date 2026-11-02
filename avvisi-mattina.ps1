# Jarvis - avvisi del mattino su Telegram, preparati SOLO sul PC (decisione dell'utente, 03/11/2026).
#   -Agenda    impegni di oggi da Machine\Contesto\Calendario.md (scritto dal Posta Agent). NON passa da Claude.
#   -Rassegna  3 notizie "In evidenza" + allerte gravi (🟠/🔴 Protezione Civile, terremoti rilevanti) della rassegna di oggi.
#              Se c'è un'allerta 🔴 o un terremoto >= M4.0: anche vocale e telefonata (CallMeBot, se configurato).
# Ogni tipo di avviso parte al massimo una volta al giorno (stato in avvisi-stato.txt, escluso da Git).
# Privatezza: Anthropic non vede nulla; il testo passa dai server di Telegram (i bot non hanno crittografia end-to-end).
# Agenda automatica alle 7:10:  powershell -ExecutionPolicy Bypass -File .\avvisi-mattina.ps1 -Schedule
# La rassegna lo chiama da sola alla fine (agents\schedule-rassegna.ps1).
param([switch]$Agenda, [switch]$Rassegna, [switch]$Schedule)
$ErrorActionPreference = 'Continue'
if ($Schedule) {
    $act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Agenda"
    $trg = New-ScheduledTaskTrigger -Daily -At 7:10
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName "Jarvis Agenda" -Action $act -Trigger $trg -Settings $set -Description "Agenda di oggi su Telegram (preparata in locale)" -Force | Out-Null
    Write-Host "Attività 'Jarvis Agenda' creata: ogni giorno alle 7:10. Prova subito: .\avvisi-mattina.ps1 -Agenda"
    return
}
$root    = Split-Path $PSScriptRoot -Parent
$machine = Join-Path $root 'DBVault\Machine'
$statoF  = Join-Path $PSScriptRoot 'avvisi-stato.txt'
. (Join-Path $PSScriptRoot 'avvisa-telegram.ps1')
$oggi = Get-Date
$iso  = $oggi.ToString('yyyy-MM-dd')
$GIORNI = @('domenica', 'lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato')
$MESI   = @('gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno', 'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre')
$etichetta = "$($GIORNI[[int]$oggi.DayOfWeek]) $($oggi.Day) $($MESI[$oggi.Month - 1])"

function GiaInviato([string]$tipo) { (Test-Path $statoF) -and (Select-String -Path $statoF -SimpleMatch "$tipo $iso" -Quiet) }
function Segna([string]$tipo) { Add-Content -Path $statoF -Value "$tipo $iso" -Encoding UTF8 }
function Sezione([string[]]$righe, [string]$titolo) {   # righe tra "## titolo" e il "## " successivo
    $dentro = $false; foreach ($r in $righe) {
        if ($r -match '^## ') { if ($dentro) { break }; $dentro = ($r.Substring(3).Trim() -ieq $titolo); continue }
        if ($dentro) { $r }
    }
}
function Pulisci([string]$t) { ($t -replace '\[([^\]]*)\]\([^)]*\)', '$1' -replace '\*\*', '' -replace '^\s*-\s*', '').Trim() }

if ($Agenda -and -not (GiaInviato 'agenda')) {
    $cal = Join-Path $machine 'Contesto\Calendario.md'
    if (-not (Test-Path $cal)) { $msg = "📅 Agenda non disponibile: manca Calendario.md (Posta Agent)" }
    else {
        $righe = Get-Content $cal -Encoding UTF8
        $agg = ($righe | Where-Object { $_ -match '^updated:\s*(\d{4}-\d{2}-\d{2})' } | Select-Object -First 1)
        $ev = @(Sezione $righe $etichetta | Where-Object { $_ -match '^\s*-\s' } | ForEach-Object { Pulisci $_ })
        if ($agg -notmatch $iso) { $msg = "📅 Agenda non aggiornata oggi (il Posta Agent non è ancora girato): apri Calendario.md in Obsidian" }
        elseif ($ev.Count -eq 0 -or ($ev.Count -eq 1 -and $ev[0] -eq 'nessun evento')) { $msg = "📅 Oggi, $etichetta`: nessun impegno" }
        else { $msg = "📅 Oggi, $etichetta`n" + (($ev | ForEach-Object { "• $_" }) -join "`n") }
    }
    if (Invia-Avviso $msg) { Segna 'agenda'; Write-Host "Agenda inviata." }
}

if ($Rassegna) {
    $f = Join-Path $machine "Research\Rassegna\$iso.md"
    if (-not (Test-Path $f)) { Write-Host "Rassegna di oggi non trovata."; return }
    $righe = Get-Content $f -Encoding UTF8
    $gravi = @(Sezione $righe 'Allerte e terremoti' | Where-Object { $_ -match '^- (🟠|🔴|🌐)' } | ForEach-Object { Pulisci $_ })
    if ($gravi.Count -gt 0 -and -not (GiaInviato 'allerte')) {
        if (Invia-Avviso ("🚨 Allerte (fonti ufficiali)`n" + (($gravi | ForEach-Object { "• $_" }) -join "`n"))) { Segna 'allerte' }
    }
    # Urgenti (03/11): allerta ROSSA o terremoto >= M4.0 -> anche vocale + telefonata (una volta al giorno).
    $urgenti = @($gravi | Where-Object { $_ -match '🔴' -or ($_ -match '🌐\s*M(\d+[.,]\d)' -and [double]($Matches[1] -replace ',', '.') -ge 4.0) })
    if ($urgenti.Count -gt 0 -and -not (GiaInviato 'urgente')) {
        $voce = "Attenzione, allerta da fonti ufficiali. " + (($urgenti | ForEach-Object { ($_ -replace '🔴|🟠|🌐', '' -replace '·', ',').Trim() }) -join '. ')
        $okV = Invia-Vocale $voce
        $okC = Chiama-Allarme "Jarvis: allerta grave dalle fonti ufficiali. Guarda Telegram."
        if ($okV -or $okC) { Segna 'urgente' }
    }
    if (-not (GiaInviato 'rassegna')) {
        $top = @(Sezione $righe 'In evidenza' | ForEach-Object { if ($_ -match '^- \*\*(.+?)\*\*') { $Matches[1] } } | Select-Object -First 3)
        $msg = "📰 Rassegna pronta" + $(if ($top.Count) { " — in evidenza:`n" + (($top | ForEach-Object { "• $_" }) -join "`n") } else { "" }) +
               "`nDettagli: Machine/Research/Rassegna/$iso.md"
        if (Invia-Avviso $msg) { Segna 'rassegna'; Write-Host "Avviso rassegna inviato." }
    }
}
