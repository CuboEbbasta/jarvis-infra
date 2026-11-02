# Avviso Telegram di Jarvis: manda UN messaggio breve al tuo account tramite il bot di Hermes.
# Uso: . .\avvisa-telegram.ps1 ; Invia-Avviso "testo"     (oppure: .\avvisa-telegram.ps1 -Testo "prova")
# Urgenti (solo allerte gravi): Invia-Vocale "testo" (vocale Isabella, container 'voce')
#                               Chiama-Allarme "testo" (telefonata Telegram via CallMeBot, solo se infra\callmebot.txt esiste)
# Prove: .\avvisa-telegram.ps1 -Vocale "prova vocale"  ·  .\avvisa-telegram.ps1 -Chiama "prova chiamata"
# Legge TELEGRAM_BOT_TOKEN e TELEGRAM_ALLOWED_USERS dal .env di Hermes SOLO in memoria: non li stampa e non li salva.
# Privatezza: il testo passa dai server di Telegram -> solo nomi di servizi e percorsi, mai contenuti personali.
param([string]$Testo, [string]$Vocale, [string]$Chiama)
function Leggi-Telegram {
    $envFile = "$env:LOCALAPPDATA\hermes\.env"
    if (-not (Test-Path $envFile)) { Write-Host "Avviso non inviato: .env di Hermes non trovato"; return $null }
    $vals = @{}
    Get-Content $envFile -Encoding UTF8 | Where-Object { $_ -match '^\s*(TELEGRAM_BOT_TOKEN|TELEGRAM_ALLOWED_USERS)\s*=' } | ForEach-Object {
        $k, $v = $_ -split '=', 2; $vals[$k.Trim()] = $v.Trim().Trim('"').Trim("'")
    }
    $token = $vals['TELEGRAM_BOT_TOKEN']; $chat = ($vals['TELEGRAM_ALLOWED_USERS'] -split ',')[0].Trim()
    if (-not $token -or -not $chat) { Write-Host "Avviso non inviato: token o ID Telegram mancanti nel .env di Hermes"; return $null }
    return @{ token = $token; chat = $chat }
}
function Invia-Avviso([string]$messaggio) {
    $tg = Leggi-Telegram; if (-not $tg) { return $false }
    $token = $tg.token; $chat = $tg.chat
    try {
        $body = @{ chat_id = $chat; text = $messaggio; disable_web_page_preview = $true } | ConvertTo-Json -Compress
        Invoke-RestMethod "https://api.telegram.org/bot$token/sendMessage" -Method Post -ContentType "application/json; charset=utf-8" `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10 | Out-Null
        return $true
    } catch { Write-Host "Avviso non inviato: Telegram non raggiungibile"; return $false }
}
function Invia-Vocale([string]$testo) {
    # Vocale con voce italiana (Edge TTS) creato nel container 'voce'. Token/chat solo in variabili di processo, poi tolti.
    $tg = Leggi-Telegram; if (-not $tg) { return $false }
    $agents = Join-Path (Split-Path $PSScriptRoot -Parent) 'agents'
    $env:TELEGRAM_BOT_TOKEN = $tg.token; $env:TELEGRAM_CHAT_ID = $tg.chat
    try {
        Push-Location $agents
        docker compose run --rm voce --testo $testo 2>&1 | Where-Object { $_ -notmatch 'TOKEN' } | Out-Host
        return ($LASTEXITCODE -eq 0)
    } catch { Write-Host "Vocale non inviato: Docker non disponibile"; return $false }
    finally { Pop-Location; Remove-Item Env:TELEGRAM_BOT_TOKEN, Env:TELEGRAM_CHAT_ID -ErrorAction SilentlyContinue }
}
function Chiama-Allarme([string]$testo) {
    # Telefonata Telegram con CallMeBot (servizio esterno gratuito): SOLO allarmi gravi.
    # Attivazione: 1) su Telegram scrivi /start a @CallMeBot_txtbot  2) crea infra\callmebot.txt con il tuo @username (escluso da Git)
    # Privatezza: il testo passa da CallMeBot e dalla sintesi Google -> solo allerte pubbliche, mai dati personali.
    $f = Join-Path $PSScriptRoot 'callmebot.txt'
    if (-not (Test-Path $f)) { Write-Host "Chiamata non fatta: callmebot.txt non configurato"; return $false }
    $user = (Get-Content $f -Encoding UTF8 | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
    if ($user -notmatch '^@\w{4,}$') { Write-Host "Chiamata non fatta: in callmebot.txt serve il tuo @username Telegram"; return $false }
    $t = $testo; if ($t.Length -gt 250) { $t = $t.Substring(0, 250) }
    Add-Type -AssemblyName System.Web
    $url = "https://api.callmebot.com/start.php?user=$([Web.HttpUtility]::UrlEncode($user))&text=$([Web.HttpUtility]::UrlEncode($t))&lang=it-IT-Standard-A&rpt=2&cc=missed"
    if ($user -eq '@tuousername') { Write-Host "Chiamata non fatta: in callmebot.txt c'è ancora il segnaposto @tuousername"; return $false }
    try {
        $r = Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60
        if ($r.Content -match 'not authorized|not received|Error|Warning') { Write-Host "Chiamata non fatta: CallMeBot non ti ha autorizzato (/start a @CallMeBot_API e username corretto)"; return $false }
        return $true
    }
    catch { Write-Host "Chiamata non fatta: CallMeBot non raggiungibile"; return $false }
}
if ($Testo)  { if (Invia-Avviso $Testo)    { Write-Host "Avviso inviato." } }
if ($Vocale) { if (Invia-Vocale $Vocale)   { Write-Host "Vocale inviato." } }
if ($Chiama) { if (Chiama-Allarme $Chiama) { Write-Host "Chiamata avviata." } }
