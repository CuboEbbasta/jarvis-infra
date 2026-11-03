# Jarvis - controllo salute: verifica che i pezzi di Jarvis funzionino e scrive il risultato nel vault.
# Non usa chiavi, non legge .env, non chiama modelli (zero token): solo controlli locali.
# Una volta:    powershell -ExecutionPolicy Bypass -File .\controllo-salute.ps1
# Automatico:   powershell -ExecutionPolicy Bypass -File .\controllo-salute.ps1 -Schedule   (ogni 2 ore)
# Risultato:    DBVault\Machine\Status\salute.md (Dashboard e briefing) + riga in Machine\Logs\events.jsonl
param([switch]$Schedule)
if ($Schedule) {
    $act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours(7) -RepetitionInterval (New-TimeSpan -Hours 2)
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName "Jarvis Salute" -Action $act -Trigger $trg -Settings $set -Force | Out-Null
    Write-Host "Controllo salute ogni 2 ore (attività 'Jarvis Salute')."
    exit
}
$jarvis  = "$env:USERPROFILE\Documents\STUDIO\Jarvis"
$machine = "$jarvis\DBVault\Machine"
$righe = New-Object System.Collections.ArrayList
$problemi = 0
$rossi = New-Object System.Collections.ArrayList   # componenti con ❌ (non funzionano)
function Esito($nome, $ok, $dettaglio, [switch]$Avviso) {
    $icona = if ($ok) { "✅" } elseif ($Avviso) { "⚠️" } else { "❌" }
    if (-not $ok) { $script:problemi++ ; if (-not $Avviso) { [void]$script:rossi.Add($nome) } }
    [void]$script:righe.Add("| $nome | $icona | $dettaglio |")
}
function Http($url) { try { (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200 } catch { $false } }
function EtaOre($file) { if (Test-Path $file) { [math]::Round(((Get-Date) - (Get-Item $file).LastWriteTime).TotalHours, 1) } else { $null } }

# 1. Servizi
docker info *> $null; $dockerOk = ($LASTEXITCODE -eq 0)
Esito "Docker" $dockerOk ($(if ($dockerOk) { "attivo" } else { "non attivo: apri Docker Desktop" }))
$oll = Http "http://localhost:11434/api/tags"
$caricati = ""
if ($oll) { try { $caricati = ((Invoke-RestMethod "http://localhost:11434/api/ps" -TimeoutSec 5).models | ForEach-Object { $_.name }) -join ", " } catch {} }
Esito "Ollama" $oll ($(if ($oll) { "attivo" + $(if ($caricati) { " · in memoria: $caricati" } else { " · nessun modello in memoria" }) } else { "non risponde su :11434" }))
$llm = Http "http://localhost:4000/health/liveliness"
Esito "LiteLLM (gateway)" $llm ($(if ($llm) { "attivo su :4000" } else { "non risponde: cd infra ; docker compose up -d" }))
$herm = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'hermes' -and $_.CommandLine -match 'gateway' }).Count -gt 0
Esito "Hermes (Telegram)" $herm ($(if ($herm) { "gateway in esecuzione" } else { "gateway fermo: hermes gateway start" })) -Avviso
# Listener delle richieste di Hermes (rassegna|posta|salute|study): se e' fermo Hermes non puo' avviare gli agenti (03/11 era fermo da ore)
$rich = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'esegui-richieste' }).Count -gt 0
Esito "Listener richieste di Hermes" $rich ($(if ($rich) { "in esecuzione" } else { "fermo: Start-ScheduledTask -TaskName 'Jarvis Richieste'" }))
$osi = Http "http://localhost:3010"
Esito "OSIRIS (mappa)" $osi ($(if ($osi) { "attivo su :3010" } else { "non risponde: cd osiris ; docker compose up -d" })) -Avviso
# Stati agente rimasti 'running' da troppo tempo (processo interrotto senza chiudere lo stato)
Get-ChildItem "$machine\Status\*-agent.json" -ErrorAction SilentlyContinue | ForEach-Object {
    try { $sj = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
    if ($sj.state -eq 'running' -and $sj.started -and ((Get-Date) - [datetime]$sj.started).TotalHours -gt 6) {
        Esito "Stato di $($sj.agent)" $false "risulta 'running' dal $(([datetime]$sj.started).ToString('dd/MM HH:mm')): processo interrotto?" -Avviso
    }
}

# 2. Risultati recenti
$oggi = Get-Date -Format "yyyy-MM-dd"
$r = Get-ChildItem "$machine\Research\Rassegna\*.md" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$ore = if ($r) { EtaOre $r.FullName } else { $null }
Esito "Rassegna" ($null -ne $ore -and $ore -lt 30) ($(if ($r) { "ultima: $($r.Name) ($ore ore fa)" } else { "mai generata" })) -Avviso
$b = "$machine\Status\backup.md"; $oreB = EtaOre $b
$statoB = if (Test-Path $b) { ((Get-Content $b -Encoding UTF8 | Where-Object { $_ -match '^state:' }) -replace 'state:\s*','') } else { "" }
Esito "Backup" ($statoB -eq "success" -and $oreB -lt 48) ($(if ($statoB) { "ultimo: $statoB ($oreB ore fa)" } else { "mai eseguito" })) -Avviso
$brief = Test-Path "$machine\Reports\Daily\$oggi-briefing.md"
Esito "Briefing di oggi" ($brief -or (Get-Date).Hour -lt 8) ($(if ($brief) { "presente" } elseif ((Get-Date).Hour -lt 8) { "non ancora (parte alle 7:10)" } else { "mancante: PC spento alle 7:10?" })) -Avviso

# 3. Attività pianificate di Windows
foreach ($t in "Jarvis Rassegna", "Jarvis Backup", "Jarvis Posta", "Jarvis Agenda") {
    $info = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    if (-not $info) { Esito "Attività '$t'" $false "non registrata" -Avviso; continue }
    $ok = $info.LastTaskResult -in 0, 267011   # 267011 = non ancora eseguita
    Esito "Attività '$t'" $ok "ultimo esito $($info.LastTaskResult) · prossima $($info.NextRunTime)" -Avviso
}

# 4. Spazio su disco
$c = Get-PSDrive C; $libGB = [math]::Round($c.Free / 1GB, 1); $pct = [math]::Round(100 * $c.Free / ($c.Free + $c.Used))
Esito "Disco C:" ($pct -ge 10) "$libGB GB liberi ($pct%)" -Avviso

# Scrittura
$stato = if ($problemi -eq 0) { "success" } else { "partial" }
$ts = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
$utf8 = New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force "$machine\Status", "$machine\Logs" | Out-Null
$md = @("---", "type: agent-status", "agent: salute", "state: $stato", "task: `"Controllo salute`"", "phase: `"finito`"",
        "progress: `"$problemi problemi`"", "model: nessuno", "updated: $ts", "ended: $ts", "result: `"$problemi problemi`"", "---",
        "# Salute di Jarvis — $(Get-Date -Format 'dd/MM HH:mm')", "", "| Componente | Esito | Dettaglio |", "|---|---|---|") + $righe +
       @("", "✅ ok · ⚠️ da guardare · ❌ non funziona. File generato automaticamente da infra/controllo-salute.ps1: non modificare.")
[IO.File]::WriteAllText("$machine\Status\salute.md", ($md -join "`n") + "`n", $utf8)
$ev = [ordered]@{ ts = $ts; agent = "salute"; run_id = (Get-Date).ToString("yyyyMMdd-HHmmss"); event = "end"; status = $stato; metrics = @{ problemi = $problemi } } | ConvertTo-Json -Compress
[IO.File]::AppendAllText("$machine\Logs\events.jsonl", $ev + "`n", $utf8)
# Avviso Telegram: solo se ci sono ❌ e solo quando l'elenco cambia (niente messaggi ripetuti ogni 2 ore)
$memo = "$machine\Status\.salute-ultimo-avviso"
$firma = ($rossi | Sort-Object) -join ", "
$prima = if (Test-Path $memo) { (Get-Content $memo -Raw -Encoding UTF8).Trim() } else { "" }
if ($firma -ne $prima) {
    . "$PSScriptRoot\avvisa-telegram.ps1"
    $testo = if ($firma) { "⚠️ Jarvis: non funziona -> $firma. Dettagli: Machine/Status/salute.md" } else { "✅ Jarvis: tutto di nuovo a posto." }
    if ($prima -or $firma) { if (Invia-Avviso $testo) { [IO.File]::WriteAllText($memo, $firma, $utf8) } }
}
$righe | ForEach-Object { Write-Host $_ }
Write-Host "Problemi: $problemi  →  $machine\Status\salute.md"
