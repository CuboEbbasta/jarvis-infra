# Jarvis Control Center - avvia l'app (API + database + web app servita dallo stesso backend).
# Uso:  powershell -ExecutionPolicy Bypass -File infra\avvia-app.ps1 [-Tailscale] [-Ricostruisci]
#   -Tailscale     pubblica l'API anche sull'IP Tailscale del PC (opt-in; mai 0.0.0.0)
#   -Ricostruisci  ricostruisce la web app (npm ci + build) e l'immagine api anche se gia' presenti
# Non legge ne' stampa il contenuto di app\.env.
param(
    [switch]$Tailscale,
    [switch]$Ricostruisci,
    [string]$TailscaleIp = '100.95.213.52'
)
# Continue: i comandi nativi (docker, npm) scrivono l'avanzamento su stderr; gli esiti si controllano con $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
$app = (Resolve-Path (Join-Path $PSScriptRoot '..\app')).Path

if (-not (Test-Path (Join-Path $app '.env'))) {
    Write-Host "Manca app\.env. Esegui prima:  powershell -ExecutionPolicy Bypass -File infra\crea-env-app.ps1"
    exit 1
}
cmd /c "docker info >nul 2>&1"
if ($LASTEXITCODE -ne 0) { Write-Host 'Docker non e'' attivo: avvia Docker Desktop (o infra\avvia-jarvis.ps1).'; exit 1 }

# IP Tailscale: solo CGNAT 100.64.0.0/10 (100.64-127.x.x), ogni ottetto 0-255
if ($Tailscale) {
    $oct = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    if ($TailscaleIp -notmatch ('^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' + $oct + '\.' + $oct + '$')) {
        Write-Host "IP Tailscale non valido: $TailscaleIp (atteso 100.64.0.0/10)"; exit 1
    }
}

# Web app: serve web\dist (montata in sola lettura nel container)
$dist = Join-Path $app 'web\dist\index.html'
if ($Ricostruisci -or -not (Test-Path $dist)) {
    Write-Host 'Costruisco la web app (npm ci && npm run build)...'
    Push-Location (Join-Path $app 'web')
    try {
        npm ci
        if ($LASTEXITCODE -ne 0) { Write-Host 'npm ci fallito'; exit 1 }
        npm run build
        if ($LASTEXITCODE -ne 0) { Write-Host 'npm run build fallito'; exit 1 }
    } finally { Pop-Location }
}

Push-Location $app
try {
    $files = @('-f', 'docker-compose.yml')
    if ($Tailscale) {
        $env:JARVIS_TAILSCALE_IP = $TailscaleIp
        $files += @('-f', 'docker-compose.tailscale.yml')
    }
    $extra = @(); if ($Ricostruisci) { $extra = @('--build') }
    docker compose @files up -d @extra
    if ($LASTEXITCODE -ne 0) { Write-Host 'docker compose up fallito'; exit 1 }
} finally {
    Remove-Item Env:\JARVIS_TAILSCALE_IP -ErrorAction SilentlyContinue
    Pop-Location
}

Write-Host 'Attendo l''API (fino a 2 minuti)...'
$ok = $false
for ($i = 0; $i -lt 60 -and -not $ok; $i++) {
    try { $ok = (Invoke-WebRequest 'http://127.0.0.1:3030/api/health' -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } catch { $ok = $false }
    if (-not $ok) { Start-Sleep 2 }
}
if (-not $ok) { Write-Host 'L''API non risponde entro 2 minuti. Guarda:  cd app; docker compose logs api --tail 50'; exit 1 }

Write-Host 'Jarvis Control Center attivo: http://127.0.0.1:3030/' -ForegroundColor Green
if ($Tailscale) { Write-Host "Dal telefono (Tailscale attivo): http://${TailscaleIp}:3030/" -ForegroundColor Green }
