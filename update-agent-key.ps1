# Jarvis - aggiorna i modelli consentiti alla chiave di un agente (la chiave resta la stessa)
# Uso: powershell -ExecutionPolicy Bypass -File .\update-agent-key.ps1 -Agent study-agent -Models local-fast,local-private,local-vision
param([Parameter(Mandatory)][string]$Agent, [Parameter(Mandatory)][string[]]$Models)
# powershell -File passa 'a,b,c' come unica stringa: la divido sulle virgole
$Models = @($Models | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$master = (Get-Content "$PSScriptRoot\.env" | Where-Object { $_ -match '^LITELLM_MASTER_KEY=' }) -replace '^LITELLM_MASTER_KEY=',''
$var = ($Agent.ToUpper() -replace '[^A-Z0-9]','_') + '_KEY'
$envFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'agents\.env'
$key = (Get-Content $envFile | Where-Object { $_ -match "^$var=" }) -replace "^$var=",''
if (-not $key) { throw "Chiave $var non trovata in agents\.env: creala con new-agent-key.ps1" }
$body = @{ key = $key; models = $Models } | ConvertTo-Json
Invoke-RestMethod -Uri 'http://localhost:4000/key/update' -Method Post -Headers @{ Authorization = "Bearer $master" } -ContentType 'application/json' -Body $body | Out-Null
Write-Host "Chiave '$Agent' aggiornata. Modelli consentiti: $($Models -join ', ')"
