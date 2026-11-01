# Jarvis - limita Ollama (porta 11434) a questo PC + Docker/WSL, chiudendolo alla rete di casa.
# Eseguire in PowerShell COME AMMINISTRATORE:
#   powershell -ExecutionPolicy Bypass -File .\firewall-ollama.ps1
# Annullare:  Get-NetFirewallRule -DisplayName "Jarvis*" | Remove-NetFirewallRule ; poi riabilitare le regole Ollama disattivate

$ErrorActionPreference = 'Stop'

# 1. Disattiva le regole "consenti" create da Windows per ollama.exe (quelle aperte a tutta la LAN)
$old = Get-NetFirewallApplicationFilter | Where-Object { $_.Program -like '*ollama*' } | Get-NetFirewallRule |
       Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and $_.DisplayName -notlike 'Jarvis*' }
$old | ForEach-Object { Write-Host "Disattivo regola: $($_.DisplayName)"; Disable-NetFirewallRule -Name $_.Name }

# 2. Consente la porta 11434 solo da localhost e dalle subnet private di Docker/WSL (172.16.0.0/12)
Get-NetFirewallRule -DisplayName 'Jarvis - Ollama da Docker/WSL' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'Jarvis - Ollama da Docker/WSL' -Direction Inbound -Action Allow `
  -Protocol TCP -LocalPort 11434 -RemoteAddress 127.0.0.1,172.16.0.0/12 -Profile Any | Out-Null

Write-Host "`nFatto. Test: dalla cartella infra lancia .\test.ps1 (deve funzionare)."
Write-Host "Da un altro dispositivo della rete, http://<IP-del-PC>:11434 NON deve rispondere."
