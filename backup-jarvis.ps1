# Jarvis - backup CIFRATO (restic) di vault, codice e config di Hermes su OneDrive. Microsoft vede solo blocchi cifrati.
# Prima volta:  winget install restic.restic   (poi riapri PowerShell)
#               powershell -ExecutionPolicy Bypass -File .\backup-jarvis.ps1 -Init
# Backup:       powershell -ExecutionPolicy Bypass -File .\backup-jarvis.ps1
# Automatico:   powershell -ExecutionPolicy Bypass -File .\backup-jarvis.ps1 -Schedule   (ogni giorno alle 23:30)
# Limite:       mai oltre 50 MB (1% di 5 GB): prima sfoltisce le copie vecchie, se non basta salta e lo segnala in Machine/Logs/events.jsonl
# Ripristino:   restic -r <repo> --password-file <file> restore latest --target C:\Ripristino
param([switch]$Init, [switch]$Schedule)
$repo = Join-Path $env:OneDrive "JarvisBackup"
$pass = Join-Path $env:USERPROFILE ".jarvis-backup-password"   # FUORI da OneDrive: senza questo file il backup è illeggibile
$env:RESTIC_REPOSITORY = $repo
$env:RESTIC_PASSWORD_FILE = $pass

if ($Init) {
    if (-not (Test-Path $pass)) {
        $bytes = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        [IO.File]::WriteAllText($pass, [Convert]::ToBase64String($bytes))
        Write-Host "Password creata in $pass"
        Write-Host "IMPORTANTE: copiala in un password manager. Se perdi PC e password, il backup non si può aprire." -ForegroundColor Yellow
    }
    restic init
    exit
}
if ($Schedule) {
    $act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $trg = New-ScheduledTaskTrigger -Daily -At 23:30
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName "Jarvis Backup" -Action $act -Trigger $trg -Settings $set -Force | Out-Null
    Write-Host "Backup automatico ogni giorno alle 23:30 (attività 'Jarvis Backup')."
    exit
}
$jarvis = "$env:USERPROFILE\Documents\STUDIO\Jarvis"
$hermes = "$env:LOCALAPPDATA\hermes"
$LimiteMB = 50   # 1% dei 5 GB gratuiti di OneDrive: il backup non lo supera MAI
$sorgenti = @($jarvis, "$hermes\config.yaml", "$hermes\SOUL.md", "$hermes\memories", "$hermes\skills", "$hermes\cron")
$esclusi = @("--exclude", "**/node_modules", "--exclude", "**/__pycache__", "--exclude", "**/rassegna-ultima.log", "--exclude", "**/osiris/src")
# Livelli di conservazione: si passa al successivo solo se lo spazio non basta
$livelli = @(
    @("--keep-daily", "7", "--keep-weekly", "4", "--keep-monthly", "6"),
    @("--keep-daily", "3", "--keep-weekly", "2", "--keep-monthly", "2"),
    @("--keep-last", "1")
)
function DimensioneMB { if (Test-Path $repo) { [math]::Round(((Get-ChildItem $repo -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB, 1) } else { 0 } }
function Evento($stato, $dettaglio) {
    # Standard Jarvis: riga in Machine/Logs/events.jsonl + stato in Machine/Status/backup.md (Dashboard)
    $machine = "$jarvis\DBVault\Machine"
    $utf8 = New-Object Text.UTF8Encoding($false)
    $ts = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz"); $mb = DimensioneMB
    $riga = [ordered]@{ ts = $ts; agent = "backup"; run_id = (Get-Date).ToString("yyyyMMdd-HHmmss"); event = "end"; status = $stato; reason = $dettaglio; metrics = @{ dimensione_mb = $mb; limite_mb = $LimiteMB } } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText("$machine\Logs\events.jsonl", $riga + "`n", $utf8)
    New-Item -ItemType Directory -Force "$machine\Status" | Out-Null
    $md = @("---", "type: agent-status", "agent: backup", "state: $stato", "task: `"Backup cifrato su OneDrive`"", "phase: `"finito`"",
            "progress: `"$mb/$LimiteMB MB`"", "model: restic", "updated: $ts", "ended: $ts", "result: `"$dettaglio`"", "---",
            "# Stato — backup", "", "File generato automaticamente: non modificare.")
    [IO.File]::WriteAllText("$machine\Status\backup.md", ($md -join "`n") + "`n", $utf8)
}
function StimaAggiuntaMB {
    # Prova a vuoto: quanto aggiungerebbe questo backup (dopo deduplicazione e compressione)
    $out = restic backup @sorgenti @esclusi --dry-run --json 2>$null | Where-Object { $_ -match '"message_type":"summary"' } | Select-Object -Last 1
    if (-not $out) { return $null }
    [math]::Round((($out | ConvertFrom-Json).data_added) / 1MB, 1)
}

$livello = 0
$stima = StimaAggiuntaMB
if ($null -eq $stima) { Evento "failed" "stima non riuscita (restic o OneDrive non disponibili)"; Write-Host "Stima non riuscita: backup annullato." -ForegroundColor Red; exit 1 }
# Se non ci sta, sfoltisce le copie vecchie un livello alla volta
while (((DimensioneMB) + $stima) -gt $LimiteMB -and $livello -lt $livelli.Count - 1) {
    $livello++
    restic forget @($livelli[$livello]) --prune --tag jarvis | Out-Null
}
if (((DimensioneMB) + $stima) -gt $LimiteMB) {
    Evento "skipped" "servirebbero $stima MB in più, limite $LimiteMB MB"
    Write-Host "Backup SALTATO: supererebbe $LimiteMB MB (ora $(DimensioneMB) MB + $stima MB). Va rivisto cosa includere." -ForegroundColor Red
    exit 2
}
restic backup @sorgenti @esclusi --tag jarvis
if ($LASTEXITCODE -ne 0) { Evento "failed" "restic backup uscito con codice $LASTEXITCODE"; exit 1 }
restic forget @($livelli[$livello]) --prune --tag jarvis | Out-Null
$mb = DimensioneMB
if ($livello -gt 0) { Evento "success" "copie ridotte al livello $livello per stare sotto $LimiteMB MB" } else { Evento "success" "ok" }
Write-Host "Backup completato: $mb MB su OneDrive (limite $LimiteMB MB, livello di conservazione $livello)."
restic snapshots --compact | Select-Object -Last 5
