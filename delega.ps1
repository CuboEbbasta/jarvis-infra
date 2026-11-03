# Jarvis - delega un compito a Codex o ad Antigravity (agy) in modo sicuro (ADR-0008).
# Prima la PRIVACY: senza -Privacy 1 (o 2 con -OkUtente) non parte. Poi il perimetro: cartelle ammesse, mai il vault.
# Esempi:
#   .\delega.ps1 -A codex -Cartella C:\Users\fonta\Documents\STUDIO\Jarvis\agents -Privacy 1 -Compito "Rivedi jarvis/gateway.py (sola lettura)"
#   .\delega.ps1 -A antigravity -Cartella C:\Users\fonta\Documents\STUDIO\Sandbox-Antigravity\ui-prototipi -Privacy 1 `
#       -ScriviFile pagina.html,pagina.css -Compito "Leggi COMPITO.md e realizzalo"
#   Aggiungi -Prova per vedere cosa farebbe senza eseguire.
# Registra una riga in Machine/Logs/events.jsonl (mai il testo del compito).
param(
  [Parameter(Mandatory)][ValidateSet('codex','antigravity')][string]$A,
  [Parameter(Mandatory)][string]$Cartella,
  [Parameter(Mandatory)][string]$Compito,
  [ValidateSet(1,2,3)][int]$Privacy = 3,
  [switch]$OkUtente,
  [string[]]$ScriviFile = @(),
  [string]$Modello = '',
  [int]$Minuti = 20,
  [switch]$Prova
)
$ErrorActionPreference = 'Stop'
$jarvis  = Split-Path $PSScriptRoot -Parent
$studio  = Split-Path $jarvis -Parent
$cartella = [IO.Path]::GetFullPath($Cartella).TrimEnd('\')

function Rifiuta($motivo) { Write-Host "RIFIUTATO: $motivo" -ForegroundColor Red; exit 2 }
function Sotto($percorso, $radice) { $p = $percorso.TrimEnd('\') + '\'; $r = $radice.TrimEnd('\') + '\'; return $p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase) }

# 1) PRIVACY
if ($Privacy -eq 3) { Rifiuta "privacy 3 (o non dichiarata): i dati restano solo sul PC. Dichiara -Privacy 1 se il compito riguarda solo codice non privato." }
if ($Privacy -eq 2 -and -not $OkUtente) { Rifiuta "privacy 2: serve l'OK esplicito dell'utente per questo compito (-OkUtente)." }

# 2) PERIMETRO: cartelle vietate
$vietate = @("$jarvis\DBVault", "$jarvis\infra", "$jarvis\hermes-data", "$jarvis\osiris", "$env:LOCALAPPDATA\hermes",
             "$env:USERPROFILE\.ssh", "$env:USERPROFILE\.codex", "$env:USERPROFILE\.codex-jarvis", "$env:USERPROFILE\.gemini",
             "$env:USERPROFILE\.lumetto", "$studio\DatiEdAltro")
foreach ($v in $vietate) { if (Sotto $cartella $v) { Rifiuta "la cartella e' vietata ($v)" } }
if (-not (Test-Path $cartella)) { Rifiuta "la cartella non esiste: $cartella" }
if (Get-ChildItem $cartella -Force -File -Filter '.env*' -ErrorAction SilentlyContinue) { Rifiuta "nella cartella c'e' un file .env: spostalo o usa una copia pulita" }

# 3) PERIMETRO: cartelle ammesse per destinazione
$ammesse = if ($A -eq 'codex') { @("$jarvis\agents", "$studio\Programmazione", "$env:USERPROFILE\Documents\Codex", "$studio\Sandbox-Antigravity") }
           else { @("$studio\Sandbox-Antigravity") }
if (-not ($ammesse | Where-Object { Sotto $cartella $_ })) { Rifiuta "$A non puo' lavorare in $cartella. Cartelle ammesse: $($ammesse -join '; ')" }
if ($A -eq 'codex' -and (Sotto $cartella "$jarvis\agents") -and (Test-Path "$cartella\.env")) { Rifiuta "agents contiene un .env" }

# 4) REGISTRO (mai il contenuto del compito)
function Registra($esito) {
  $riga = [ordered]@{ ts = (Get-Date).ToString('s'); evento = 'delega'; a = $A; cartella = $cartella.Replace("$studio\", ''); privacy = $Privacy; esito = $esito } | ConvertTo-Json -Compress
  $log = "$jarvis\DBVault\Machine\Logs\events.jsonl"
  if (Test-Path (Split-Path $log)) { Add-Content -Path $log -Value $riga -Encoding utf8 }
}

if ($A -eq 'codex') {
  $env:CODEX_HOME = Join-Path $env:USERPROFILE '.codex-jarvis'
  $argomenti = @('exec', '-c', 'approval_policy="never"', '--cd', $cartella)
  if (-not (Test-Path "$cartella\.git")) { $argomenti += '--skip-git-repo-check' }
  if ($Modello) { $argomenti += @('-m', $Modello) }
  if ($Prova) { Write-Host "[prova] codex $($argomenti -join ' ') <compito>"; Registra 'prova'; exit 0 }
  $ErrorActionPreference = 'Continue'
  $out = '' | codex @argomenti $Compito 2>&1 | Out-String
  Registra 'eseguito'; Write-Output $out; exit 0
}

# antigravity
$agy = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
if (-not (Test-Path $agy)) { Rifiuta "agy non installato ($agy)" }
$bf = $cartella.Replace('\', '/')
$regole = New-Object System.Collections.ArrayList
$regole.Add("read_file($bf/**)") | Out-Null; $regole.Add("list_dir($bf)") | Out-Null; $regole.Add("list_directory($bf)") | Out-Null
Get-ChildItem $cartella -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $regole.Add("read_file($($_.FullName.Replace('\','/')))") | Out-Null }
foreach ($f in $ScriviFile) {
  if ($f -match '[\\/]\.\.|^\.\.|:|^[\\/]') { Rifiuta "nome di file non valido: $f" }
  $regole.Add("write_file($bf/$f)") | Out-Null
}
$json = '{"allowNonWorkspaceAccess": false, "enableTerminalSandbox": true, "toolPermission": "request-review", "agentMode": "default", "permissions": {"allow": [' + (($regole | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']}}'
$settings = Join-Path $env:USERPROFILE '.gemini\antigravity-cli\settings.json'
$model = if ($Modello) { $Modello } else { 'gemini-3.8-flash-high' }
if ($Prova) { Write-Host "[prova] agy -p <compito> --model $model --sandbox ; regole allow: $($regole.Count) (scrittura: $($ScriviFile -join ', '))"; Registra 'prova'; exit 0 }
[IO.File]::WriteAllText($settings, $json + "`n", (New-Object Text.UTF8Encoding $false))
Set-Location $cartella
$ErrorActionPreference = 'Continue'
$prompt = "$Compito`nVINCOLI: nessun comando di terminale; scrivi file solo con lo strumento di scrittura e solo i file consentiti ($($ScriviFile -join ', ')). Se uno strumento viene negato, scrivi il nome e fermati."
$out = & $agy -p $prompt --model $model --output-format json --print-timeout "${Minuti}m" --sandbox 2>&1 | Out-String
Registra 'eseguito'; Write-Output $out
