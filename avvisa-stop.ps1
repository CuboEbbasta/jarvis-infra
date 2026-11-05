# Jarvis - hook "Stop" di Claude Code: avvisa su Telegram (via bot di Hermes) quando Claude Code smette di lavorare.
# Al massimo UN avviso ogni 10 minuti, per non riempirti di messaggi durante una chat normale.
# Non stampa nulla e non fallisce mai (un hook rotto non deve bloccare il lavoro). Testo fisso: nessun contenuto della chat.
$ErrorActionPreference = 'SilentlyContinue'
$null = [Console]::In.ReadToEnd()          # svuota l'input JSON dell'hook
$stato = Join-Path $env:TEMP 'jarvis-ultimo-avviso-stop.txt'
if (Test-Path $stato) {
    $ultimo = [datetime]::MinValue
    if ([datetime]::TryParse((Get-Content $stato -Raw).Trim(), [ref]$ultimo) -and ((Get-Date) - $ultimo).TotalMinutes -lt 10) { exit 0 }
}
Set-Content $stato (Get-Date).ToString('o') -Encoding ASCII
. "$PSScriptRoot\avvisa-telegram.ps1"
$ora = (Get-Date).ToString('HH:mm')
Invia-Avviso "Claude Code ha smesso di lavorare ($ora). Torna al PC o apri la sessione per vedere cosa e' stato fatto e cosa aspetta una tua risposta." | Out-Null
exit 0
