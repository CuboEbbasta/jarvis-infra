# Jarvis - avvio dopo l'accensione del PC. Avvia solo ciò che è spento (si può lanciare quante volte vuoi), poi fa il controllo salute.
# Ordine: Ollama -> Docker Desktop -> LiteLLM + database (Docker) -> Hermes (Telegram) -> controllo salute.
# Uso a mano:          powershell -ExecutionPolicy Bypass -File C:\Users\fonta\Documents\STUDIO\Jarvis\infra\avvia-jarvis.ps1
# Automatico all'accesso a Windows (una volta sola):  ... -File ...\avvia-jarvis.ps1 -Schedule
# Non legge né stampa chiavi.
param([switch]$Schedule)
$jarvis = "$env:USERPROFILE\Documents\STUDIO\Jarvis"

if ($Schedule) {
    $act = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $trg.Delay = "PT1M"   # aspetta 1 minuto dopo l'accesso
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName "Jarvis Avvio" -Action $act -Trigger $trg -Settings $set -Force | Out-Null
    Write-Host "Avvio automatico registrato: 1 minuto dopo ogni accesso a Windows (attività 'Jarvis Avvio')."
    exit
}

function Http($url) { try { (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200 } catch { $false } }
function DockerOk { docker info *> $null; $LASTEXITCODE -eq 0 }
function HermesOk { @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'hermes' -and $_.CommandLine -match 'gateway' }).Count -gt 0 }
function Attendi($nome, [scriptblock]$prova, $secondi) {
    $fine = (Get-Date).AddSeconds($secondi)
    while (-not (& $prova)) {
        if ((Get-Date) -gt $fine) { Write-Host "  ❌ $nome non è partito entro $secondi secondi" -ForegroundColor Red; return $false }
        Start-Sleep 3
    }
    Write-Host "  ✅ $nome attivo" -ForegroundColor Green; return $true
}

Write-Host "1. Ollama (modelli locali)"
if (-not (Http "http://localhost:11434/api/tags")) {
    $app = "$env:LOCALAPPDATA\Programs\Ollama\ollama app.exe"
    if (Test-Path $app) { Start-Process $app } else { Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden }
}
Attendi "Ollama" { Http "http://localhost:11434/api/tags" } 60 | Out-Null

Write-Host "2. Docker Desktop"
if (-not (DockerOk)) { Start-Process "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe" }
$docker = Attendi "Docker" { DockerOk } 180

Write-Host "3. LiteLLM (gateway dei modelli) e database"
if ($docker) {
    docker compose -f "$jarvis\infra\docker-compose.yml" up -d 2>$null | Out-Null
    Attendi "LiteLLM" { Http "http://localhost:4000/health/liveliness" } 120 | Out-Null
} else { Write-Host "  saltato: Docker non è attivo" -ForegroundColor Yellow }

Write-Host "4. Hermes (Telegram)"
if (-not (HermesOk)) { hermes gateway start 2>$null | Out-Null }
Attendi "Hermes" { HermesOk } 60 | Out-Null

Write-Host "5. Controllo salute"
& "$PSScriptRoot\controllo-salute.ps1"
