# Jarvis - crea una richiesta per gli agenti SENZA passare dal modello (usato dai comandi fissi di Hermes: /dashboard, /rassegna, ...).
# Elenco chiuso: solo le azioni qui sotto. Nessun testo libero. 'study' resta fuori (occupa la GPU: si chiede prima).
# Uso: powershell -NoProfile -ExecutionPolicy Bypass -File richiesta-rapida.ps1 dashboard
param([Parameter(Mandatory, Position = 0)][string]$Azione)
$ammesse = @('rassegna', 'posta', 'salute', 'dashboard')
if ($ammesse -notcontains $Azione) { Write-Output "Azione non ammessa. Ammesse: $($ammesse -join ', ')"; exit 2 }
$cartella = Join-Path (Split-Path $PSScriptRoot -Parent) 'DBVault\Machine\Richieste'
if (-not (Test-Path $cartella)) { Write-Output "Cartella richieste non trovata."; exit 3 }
$nome = '{0}_{1}.txt' -f (Get-Date).ToString('yyyy-MM-dd_HHmmss'), $Azione
[IO.File]::WriteAllText((Join-Path $cartella $nome), "$Azione`r`n", (New-Object Text.UTF8Encoding $false))
Write-Output "Fatto, avviato: $Azione (entro circa 30 secondi; ti avviso a fine lavoro)."
