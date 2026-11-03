# Jarvis - revoca chiavi LiteLLM per alias (es. chiavi di prova non piu' usate).
# Uso: powershell -ExecutionPolicy Bypass -File .\revoca-chiave.ps1 -Alias osiris-oi,osiris-oi-2
param([Parameter(Mandatory)][string[]]$Alias)
$Alias = @($Alias | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$master = (Get-Content "$PSScriptRoot\.env" | Where-Object { $_ -match '^LITELLM_MASTER_KEY=' }) -replace '^LITELLM_MASTER_KEY=',''
$body = @{ key_aliases = $Alias } | ConvertTo-Json
try {
  $r = Invoke-RestMethod -Uri 'http://localhost:4000/key/delete' -Method Post -Headers @{ Authorization = "Bearer $master" } -ContentType 'application/json' -Body $body
  Write-Host "Chiavi revocate per gli alias: $($Alias -join ', ')"
} catch {
  Write-Host "Errore nella revoca: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
