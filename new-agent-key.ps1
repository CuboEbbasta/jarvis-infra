# Jarvis - crea una chiave LiteLLM dedicata a un agente (solo modelli locali, con budget) e la salva in agents/.env
# Uso: powershell -ExecutionPolicy Bypass -File .\new-agent-key.ps1 -Agent study-agent
param([Parameter(Mandatory)][string]$Agent, [string[]]$Models = @('local-fast','local-private'), [double]$BudgetUsd = 1, [string]$EnvFile = '')

# powershell -File passa 'a,b,c' come unica stringa: la divido sulle virgole
$Models = @($Models | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$master = (Get-Content "$PSScriptRoot\.env" | Where-Object { $_ -match '^LITELLM_MASTER_KEY=' }) -replace '^LITELLM_MASTER_KEY=',''
$body = @{ key_alias = $Agent; models = $Models; max_budget = $BudgetUsd; budget_duration = '30d'; metadata = @{ agent = $Agent } } | ConvertTo-Json
$r = Invoke-RestMethod -Uri 'http://localhost:4000/key/generate' -Method Post -Headers @{ Authorization = "Bearer $master" } -ContentType 'application/json' -Body $body

$var = ($Agent.ToUpper() -replace '[^A-Z0-9]','_') + '_KEY'
$envFile = if ($EnvFile) { $EnvFile } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'agents\.env' }
# @(...) obbligatorio: con una sola riga Get-Content restituisce una stringa e += la concatenerebbe sulla stessa riga
$lines = @(); if (Test-Path $envFile) { $lines = @(Get-Content $envFile | Where-Object { $_ -notmatch "^$var=" }) }
$lines += "$var=$($r.key)"
Set-Content -Path $envFile -Value $lines -Encoding ascii
Write-Host "Chiave per '$Agent' creata (modelli: $($Models -join ', '); budget: $BudgetUsd USD / 30 giorni)."
Write-Host "Salvata in $envFile come $var. Visibile nella UI: http://localhost:4000/ui -> Virtual Keys"
