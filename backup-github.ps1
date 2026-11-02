# Jarvis - backup su GitHub in repo PRIVATI. Sostituisce backup-jarvis.ps1 (OneDrive), deciso il 02/11/2026.
# Su GitHub: agents (jarvis-agents), infra (jarvis-infra), vault SENZA Human/ (jarvis-vault),
#            configurazione: .claude, CLAUDE.md, hermes-data, osiris (jarvis-config).
# MAI su GitHub: Human/ (Git solo locale in DBVault\Human\.git), file .env, chiavi, .env/config.yaml/memorie di Hermes.
# Prima di ogni commit controlla: niente .env/chiavi, niente segreti nel testo, niente Human/, niente file > 50 MB.
# Uso:         powershell -ExecutionPolicy Bypass -File .\backup-github.ps1
# Automatico:  powershell -ExecutionPolicy Bypass -File .\backup-github.ps1 -Schedule   (ogni giorno alle 23:30)
param([switch]$Schedule)
$jarvis  = "$env:USERPROFILE\Documents\STUDIO\Jarvis"
$hermes  = "$env:LOCALAPPDATA\hermes"
$machine = "$jarvis\DBVault\Machine"

if ($Schedule) {
    $act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $trg = New-ScheduledTaskTrigger -Daily -At 23:30
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName "Jarvis Backup" -Action $act -Trigger $trg -Settings $set -Force | Out-Null
    Write-Host "Backup su GitHub automatico ogni giorno alle 23:30 (attività 'Jarvis Backup')."
    exit
}

$nomiVietati = '(^|/)(\.env(\..+)?|[^/]*\.(pem|key|pfx|p12)|id_rsa[^/]*|\.jarvis-backup-password)$'
$segreti = 'sk-[A-Za-z0-9_\-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|\b\d{8,10}:AA[A-Za-z0-9_\-]{30,}|AIza[0-9A-Za-z_\-]{35}'
$utf8 = New-Object Text.UTF8Encoding($false)

function Evento($stato, $dettaglio, $ok, $tot) {
    # Standard Jarvis: riga in Machine/Logs/events.jsonl + stato in Machine/Status/backup.md (Dashboard, controllo salute)
    $ts = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    $riga = [ordered]@{ ts = $ts; agent = "backup"; run_id = (Get-Date).ToString("yyyyMMdd-HHmmss"); event = "end"; status = $stato; reason = $dettaglio; metrics = @{ repo_ok = $ok; repo_totali = $tot } } | ConvertTo-Json -Compress
    [IO.File]::AppendAllText("$machine\Logs\events.jsonl", $riga + "`n", $utf8)
    New-Item -ItemType Directory -Force "$machine\Status" | Out-Null
    $md = @("---", "type: agent-status", "agent: backup", "state: $stato", "task: `"Backup su GitHub (repo privati)`"", "phase: `"finito`"",
            "progress: `"$ok/$tot repo`"", "model: git", "updated: $ts", "ended: $ts", "result: `"$dettaglio`"", "---",
            "# Stato — backup", "", "File generato automaticamente: non modificare.")
    [IO.File]::WriteAllText("$machine\Status\backup.md", ($md -join "`n") + "`n", $utf8)
}

function Salva($nome, $dir, [switch]$SoloLocale, [switch]$Vault) {
    if (-not (Test-Path "$dir\.git")) { return "$nome`: repo non inizializzato" }
    git -C $dir add -A 2>$null
    $nomi = @(git -C $dir diff --cached --name-only)
    if ($nomi.Count -gt 0) {
        $prob = @()
        $prob += $nomi | Where-Object { $_ -match $nomiVietati -and $_ -notmatch '\.env\.example$' } | ForEach-Object { "file vietato $_" }
        if ($Vault) { $prob += $nomi | Where-Object { $_ -like 'Human/*' -and $_ -ne 'Human/AGENTS.md' } | ForEach-Object { "Human/ $_" } }
        $prob += $nomi | Where-Object { $p = Join-Path $dir $_; (Test-Path $p -PathType Leaf) -and (Get-Item $p).Length -gt 50MB } | ForEach-Object { "file > 50 MB $_" }
        $aggiunte = (git -C $dir diff --cached -U0 --no-color) -join "`n"
        if ([regex]::IsMatch($aggiunte, "(?m)^\+.*($segreti)")) { $prob += "possibile segreto nel testo" }
        if ($prob.Count -gt 0) {
            git -C $dir reset -q
            Write-Host "$nome BLOCCATO: $($prob -join '; ')" -ForegroundColor Red
            return "$nome bloccato ($($prob.Count) problemi, nessun nome di file segreto nel log)"
        }
        git -C $dir commit -q -m "Backup automatico $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"
        if ($LASTEXITCODE -ne 0) { return "$nome`: commit fallito" }
    }
    if ($SoloLocale) {
        if (git -C $dir remote) { return "$nome`: ha un remoto, non deve averlo" }
        return $null
    }
    git -C $dir remote get-url origin 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { return "$nome`: nessun remoto GitHub" }
    git -C $dir push -q origin HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return "$nome`: push fallito" }
    return $null
}

# 1. Copia di Hermes nel repo jarvis-config: solo SOUL.md e skills (mai .env, config.yaml, memorie)
$live = "$jarvis\hermes-data\live"
New-Item -ItemType Directory -Force $live | Out-Null
if (Test-Path "$hermes\SOUL.md") { Copy-Item "$hermes\SOUL.md" "$live\SOUL.md" -Force }
if (Test-Path "$hermes\skills") {
    $mb = ((Get-ChildItem "$hermes\skills" -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB
    if ($mb -lt 20) { robocopy "$hermes\skills" "$live\skills" /MIR /XF .env* *.key *.pem /NFL /NDL /NJH /NJS /NP | Out-Null }
}

# 2. Commit e push
$errori = @()
$errori += Salva "jarvis-agents" "$jarvis\agents"
$errori += Salva "jarvis-infra"  "$jarvis\infra"
$errori += Salva "Human (locale)" "$jarvis\DBVault\Human" -SoloLocale
$errori += Salva "jarvis-config" $jarvis
$errori = @($errori | Where-Object { $_ })
$tot = 5
# Il vault per ultimo, dopo aver scritto lo stato, così backup.md ed events.jsonl entrano nello stesso commit
$ok = $tot - 1 - $errori.Count
$stato = if ($errori.Count -eq 0) { "success" } elseif ($ok -gt 0) { "partial" } else { "failed" }
Evento $stato $(if ($errori.Count) { $errori -join "; " } else { "ok" }) ($ok + 1) $tot
$eVault = Salva "jarvis-vault" "$jarvis\DBVault" -Vault
if ($eVault) { Evento "partial" (($errori + $eVault) -join "; ") $ok $tot; $errori += $eVault }

if ($errori.Count -eq 0) { Write-Host "Backup su GitHub completato: $tot/$tot." -ForegroundColor Green }
else { Write-Host "Backup con problemi:" -ForegroundColor Yellow; $errori | ForEach-Object { Write-Host " - $_" } ; exit 1 }
