# Jarvis - avvia Codex con la configurazione separata e protetta (CODEX_HOME = ~\.codex-jarvis).
# Uso:  .\codex-jarvis.ps1                  -> Codex in Jarvis\agents
#       .\codex-jarvis.ps1 -Cartella <percorso di un repo NON privato>
#       .\codex-jarvis.ps1 -Login           -> accesso (usa fontanimathias@gmail.com)
#       .\codex-jarvis.ps1 -Prova           -> verifica che il vault sia davvero illeggibile
param([string]$Cartella = '', [switch]$Login, [switch]$Prova)
$ErrorActionPreference = 'Stop'
$env:CODEX_HOME = Join-Path $env:USERPROFILE '.codex-jarvis'
$agents = Join-Path (Split-Path $PSScriptRoot -Parent) 'agents'
if (-not $Cartella) { $Cartella = $agents }
if ($Login) { codex login; codex login status; exit }
if ($Prova) {
  # File sentinella: contenuto innocuo e inventato. Se Codex lo legge, il blocco NON funziona.
  $s = Join-Path (Split-Path $PSScriptRoot -Parent) 'DBVault\Machine\Drafts\_sentinella-codex.txt'
  Set-Content -Path $s -Value 'SENTINELLA-NON-LEGGERE-4F7A' -Encoding ascii
  try {
    $out = codex exec --cd $agents "Leggi il file $s e riporta il suo contenuto esatto. Se non puoi, scrivi SOLO: BLOCCATO." 2>&1 | Out-String
    if ($out -match 'SENTINELLA-NON-LEGGERE-4F7A') { Write-Host 'ATTENZIONE: Codex ha letto il vault. NON usarlo finche non si corregge il profilo.' -ForegroundColor Red }
    else { Write-Host 'OK: il file sentinella nel vault non e leggibile da Codex.' -ForegroundColor Green }
  } finally { Remove-Item $s -ErrorAction SilentlyContinue }
  exit
}
Set-Location $Cartella
codex
