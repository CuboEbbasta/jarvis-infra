# Avviso Telegram di Jarvis: manda UN messaggio breve al tuo account tramite il bot di Hermes.
# Uso: . .\avvisa-telegram.ps1 ; Invia-Avviso "testo"     (oppure: .\avvisa-telegram.ps1 -Testo "prova")
# Legge TELEGRAM_BOT_TOKEN e TELEGRAM_ALLOWED_USERS dal .env di Hermes SOLO in memoria: non li stampa e non li salva.
# Privatezza: il testo passa dai server di Telegram -> solo nomi di servizi e percorsi, mai contenuti personali.
param([string]$Testo)
function Invia-Avviso([string]$messaggio) {
    $envFile = "$env:LOCALAPPDATA\hermes\.env"
    if (-not (Test-Path $envFile)) { Write-Host "Avviso non inviato: .env di Hermes non trovato"; return $false }
    $vals = @{}
    Get-Content $envFile -Encoding UTF8 | Where-Object { $_ -match '^\s*(TELEGRAM_BOT_TOKEN|TELEGRAM_ALLOWED_USERS)\s*=' } | ForEach-Object {
        $k, $v = $_ -split '=', 2; $vals[$k.Trim()] = $v.Trim().Trim('"').Trim("'")
    }
    $token = $vals['TELEGRAM_BOT_TOKEN']; $chat = ($vals['TELEGRAM_ALLOWED_USERS'] -split ',')[0].Trim()
    if (-not $token -or -not $chat) { Write-Host "Avviso non inviato: token o ID Telegram mancanti nel .env di Hermes"; return $false }
    try {
        $body = @{ chat_id = $chat; text = $messaggio; disable_web_page_preview = $true } | ConvertTo-Json -Compress
        Invoke-RestMethod "https://api.telegram.org/bot$token/sendMessage" -Method Post -ContentType "application/json; charset=utf-8" `
            -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 10 | Out-Null
        return $true
    } catch { Write-Host "Avviso non inviato: Telegram non raggiungibile"; return $false }
}
if ($Testo) { if (Invia-Avviso $Testo) { Write-Host "Avviso inviato." } }
