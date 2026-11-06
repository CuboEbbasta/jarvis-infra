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
if (Get-ChildItem $cartella -Recurse -Force -File -Filter '.env*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'example|sample|esempio' }) { Rifiuta "nella cartella (o in una sottocartella) c'e' un file .env: spostalo o usa una copia pulita" }
if ($Compito -match '^\s*-') { Rifiuta "il compito non puo' iniziare con '-' (verrebbe letto come opzione del programma)" }

# 3) PERIMETRO: cartelle ammesse per destinazione
$ammesse = if ($A -eq 'codex') { @("$jarvis\agents", "$studio\Programmazione", "$env:USERPROFILE\Documents\Codex", "$studio\Sandbox-Antigravity") }
           else { @("$studio\Sandbox-Antigravity") }
if (-not ($ammesse | Where-Object { Sotto $cartella $_ })) { Rifiuta "$A non puo' lavorare in $cartella. Cartelle ammesse: $($ammesse -join '; ')" }
if ($A -eq 'codex' -and (Sotto $cartella "$jarvis\agents") -and (Test-Path "$cartella\.env")) { Rifiuta "agents contiene un .env" }

# 3b) GIORNI RISERVATI: l'utente usa Gemini dall'app in certi giorni (ogni 2 venerdi'); le quote potrebbero essere condivise (non confermato da Google)
#     -> in quei giorni Antigravity non parte, salvo -OkUtente. Elenco in infra\antigravity-giorni-riservati.txt (una data AAAA-MM-GG per riga).
if ($A -eq 'antigravity') {
  $giorni = Join-Path $PSScriptRoot 'antigravity-giorni-riservati.txt'
  if ((Test-Path $giorni) -and -not $OkUtente) {
    $oggi = (Get-Date).ToString('yyyy-MM-dd')
    if (Get-Content $giorni | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $oggi }) { Rifiuta "oggi ($oggi) e' un giorno riservato all'app Gemini: Antigravity non parte (usa -OkUtente solo se l'utente lo autorizza)." }
  }
  # Blocco fino al reset della quota (scritto da questo script quando Antigravity segnala la quota finita)
  # La quota e' PER MODELLO: una riga per modello "modello|AAAA-MM-GGTHH:MM:SS" (una riga con la sola data vale per il modello predefinito).
  # Se il modello richiesto (o il predefinito) e' bloccato e NON e' stato imposto con -Modello, si passa al primo non bloccato dell'elenco.
  $blocco = Join-Path $PSScriptRoot 'antigravity-blocco-fino-a.txt'
  $blocchi = @{}
  if (Test-Path $blocco) {
    foreach ($riga in (Get-Content $blocco)) {
      $r = $riga.Trim(); if (-not $r) { continue }
      $nome = 'gemini-3.8-flash-high'; $quando = $r
      if ($r -match '^([^|]+)\|(.+)$') { $nome = $Matches[1].Trim(); $quando = $Matches[2].Trim() }
      $f = [datetime]::MinValue
      if ([datetime]::TryParse($quando, [ref]$f)) { $blocchi[$nome] = $f }
    }
  }
  $preferenze = @('gemini-3.8-flash-high', 'gemini-3.8-flash-medium', 'gemini-3.8-flash-low', 'claude-sonnet-4-6', 'gpt-oss-120b-medium')
  $model = if ($Modello) { $Modello } else { 'gemini-3.8-flash-high' }
  if ($blocchi.ContainsKey($model) -and (Get-Date) -lt $blocchi[$model]) {
    $alt = if ($Modello) { $null } else { $preferenze | Where-Object { -not ($blocchi.ContainsKey($_) -and (Get-Date) -lt $blocchi[$_]) } | Select-Object -First 1 }
    if ($alt) { Write-Host "Modello ${model} in quota esaurita fino al $($blocchi[$model].ToString('dd/MM HH:mm')): uso $alt." -ForegroundColor Yellow; $model = $alt }
    else { Rifiuta "quota di Antigravity finita per ${model}: ritenta dopo il $($blocchi[$model].ToString('dd/MM HH:mm'))." }
  }
  # Tetto giornaliero: al massimo 2 lavori reali al giorno, per non consumare la quota dell'abbonamento (condivisa con altro? non confermato)
  $logDeleghe = "$jarvis\DBVault\Machine\Logs\events.jsonl"
  if ((Test-Path $logDeleghe) -and -not $OkUtente -and -not $Prova) {
    $oggiIso = (Get-Date).ToString('yyyy-MM-dd')
    $fatte = @(Get-Content $logDeleghe -Encoding UTF8 | Where-Object { $_ -match '"a":"antigravity"' -and $_ -match '"esito":"eseguito"' -and $_ -match "`"ts`":`"$oggiIso" }).Count
    if ($fatte -ge 2) { Rifiuta "tetto giornaliero raggiunto: Antigravity ha gia' fatto $fatte lavori oggi (massimo 2, per non esaurire la quota)." }
  }
}

# 4) REGISTRO (mai il contenuto del compito)
function Registra($esito) {
  $riga = [ordered]@{ ts = (Get-Date).ToString('s'); evento = 'delega'; a = $A; cartella = $cartella.Replace("$studio\", ''); privacy = $Privacy; esito = $esito } | ConvertTo-Json -Compress
  $log = "$jarvis\DBVault\Machine\Logs\events.jsonl"
  if (Test-Path (Split-Path $log)) { Add-Content -Path $log -Value $riga -Encoding utf8 }
  if ($esito -eq 'eseguito') {  # avviso su Telegram via Hermes: solo chi ha finito e dove, mai il testo del compito
    try {
      . "$PSScriptRoot\avvisa-telegram.ps1"
      $spunta = [char]::ConvertFromUtf32(0x2705)   # niente emoji letterali: PowerShell 5.1 senza BOM le rovina
      Invia-Avviso "$spunta $A ha terminato l'esecuzione in $($cartella.Replace("$studio\", '')). Controlla l'esito (puo' essere anche un blocco)." | Out-Null
    } catch {}
  }
}

if ($A -eq 'codex') {
  $env:CODEX_HOME = Join-Path $env:USERPROFILE '.codex-jarvis'
  $argomenti = @('exec', '-c', 'approval_policy="never"', '--cd', $cartella)
  if (-not (Test-Path "$cartella\.git")) { $argomenti += '--skip-git-repo-check' }
  if ($Modello) { $argomenti += @('-m', $Modello) }
  if ($Prova) { Write-Host "[prova] codex $($argomenti -join ' ') <compito>"; Registra 'prova'; exit 0 }
  $ErrorActionPreference = 'Continue'
  $out = '' | codex @argomenti $Compito 2>&1 | Out-String
  Registra 'eseguito'; Write-Output $out
  # Piano gratuito: se Codex segnala il limite di utilizzo, avvisa su Telegram (senza testo del compito)
  $coda = (($out -split "`n") | Select-Object -Last 15) -join "`n"   # solo la fine dell'output: una revisione che cita "quota" non deve far scattare l'avviso
  if ($coda -match '(?i)usage limit|rate.?limit exceeded|quota (exceeded|reached)|limit reached|too many requests|insufficient_quota') {
    try { . "$PSScriptRoot\avvisa-telegram.ps1"; Invia-Avviso "Codex ha segnalato un limite di utilizzo (token o quota finiti). Riprova piu' tardi o usa un altro strumento." | Out-Null } catch {}
  }
  exit 0
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
if (-not $model) { $model = if ($Modello) { $Modello } else { 'gemini-3.8-flash-high' } }
if ($Prova) { Write-Host "[prova] agy -p <compito> --model $model --sandbox ; regole allow: $($regole.Count) (scrittura: $($ScriviFile -join ', '))"; Registra 'prova'; exit 0 }
[IO.File]::WriteAllText($settings, $json + "`n", (New-Object Text.UTF8Encoding $false))
Set-Location $cartella
$ErrorActionPreference = 'Continue'
$prompt = "$Compito`nVINCOLI: nessun comando di terminale; scrivi file solo con lo strumento di scrittura e solo i file consentiti ($($ScriviFile -join ', ')). Se uno strumento viene negato, scrivi il nome e fermati."
$out = & $agy -p $prompt --model $model --output-format json --print-timeout "${Minuti}m" --sandbox 2>&1 | Out-String
if ($out -match '"status"\s*:\s*"ERROR"' -and $out -match '(?i)RESOURCE_EXHAUSTED|quota reached') {   # solo se l'esecuzione e' davvero finita in errore; abbonamento: avvisa quando la quota di Antigravity e' finita
  $quando = if ($out -match 'Resets in ([0-9hms]+)') { " Si resetta fra $($Matches[1])." } else { '' }
  if ($out -match 'Resets in (?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?') {   # ricorda fino a quando non lanciare piu' nulla
    $ore = [int]($Matches[1] -as [int]); $min = [int]($Matches[2] -as [int])
    $fileBlocco = Join-Path $PSScriptRoot 'antigravity-blocco-fino-a.txt'
    $altre = @(); if (Test-Path $fileBlocco) { $altre = @(Get-Content $fileBlocco | Where-Object { $_.Trim() -and -not $_.StartsWith("$model|") }) }
    $altre += "$model|" + (Get-Date).AddHours($ore).AddMinutes($min + 5).ToString('s')
    Set-Content $fileBlocco $altre -Encoding ASCII
  }
  try { . "$PSScriptRoot\avvisa-telegram.ps1"; Invia-Avviso "Antigravity ha finito la quota di utilizzo.$quando" | Out-Null } catch {}
}
Registra 'eseguito'; Write-Output $out
