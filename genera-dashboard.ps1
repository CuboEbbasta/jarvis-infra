# Jarvis - genera la dashboard con DATI REALI dello stato dei servizi e degli agenti.
# Prende la grafica da Sandbox-Antigravity\ui-prototipi (dashboard.html/css/js) e scrive dati-reali.js accanto.
# Output: DBVault\Machine\Dashboard-web\dashboard.html  (si apre con doppio clic; solo sul PC)
# Uso: powershell -ExecutionPolicy Bypass -File .\genera-dashboard.ps1 [-Apri]
# Non include contenuti di email/calendario/finanze: solo stato dei servizi e degli agenti.
param([switch]$Apri)
$ErrorActionPreference = 'Continue'
$jarvis = Split-Path $PSScriptRoot -Parent
$studio = Split-Path $jarvis -Parent
$sorgente = Join-Path $studio 'Sandbox-Antigravity\ui-prototipi'
$uscita = Join-Path $jarvis 'DBVault\Machine\Dashboard-web'
$stato = Join-Path $jarvis 'DBVault\Machine\Status'
if (-not (Test-Path "$sorgente\dashboard.html")) { Write-Host "Manca la grafica in $sorgente" -ForegroundColor Red; exit 1 }
New-Item -ItemType Directory -Force $uscita | Out-Null

function Prova-Url($url) { try { (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 4).StatusCode -lt 500 } catch { $false } }
$ora = (Get-Date).ToString('HH:mm')
function Servizio($id, $nome, $ok, $dettOk, $dettKo) {
  [ordered]@{ id = $id; nome = $nome; stato = $(if ($ok) { 'online' } else { 'error' }); ultimoControllo = "alle $ora"; dettaglio = $(if ($ok) { $dettOk } else { $dettKo }) }
}

# --- servizi
$hermesOk = $false
$pidFile = Join-Path $env:LOCALAPPDATA 'hermes\gateway.pid'
if (Test-Path $pidFile) { $raw = (Get-Content $pidFile -Raw); if ($raw -match '(\d{2,})') { $hermesOk = [bool](Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue) } }
$servizi = @(
  (Servizio 'hermes'  'Hermes (Telegram)' $hermesOk 'Gateway attivo, modello locale' 'Gateway non attivo: avvia infra\avvia-jarvis.ps1'),
  (Servizio 'litellm' 'LiteLLM'           (Prova-Url 'http://localhost:4000/health/liveliness') 'Gateway dei modelli raggiungibile' 'Non risponde su localhost:4000'),
  (Servizio 'ollama'  'Ollama'            (Prova-Url 'http://localhost:11434/api/tags') 'Modelli locali disponibili' 'Non risponde su localhost:11434'),
  (Servizio 'osiris'  'OSIRIS'            (Prova-Url 'http://localhost:3010') 'Mappa su localhost:3010' 'Non risponde su localhost:3010')
)

# --- agenti (da Machine\Status\*.json)
function Formatta-Quando($iso) {
  if (-not $iso) { return '-' }
  $d = [datetime]$iso
  if ($d.Date -eq (Get-Date).Date) { return "Oggi $($d.ToString('HH:mm'))" }
  if ($d.Date -eq (Get-Date).Date.AddDays(-1)) { return "Ieri $($d.ToString('HH:mm'))" }
  return $d.ToString('dd/MM HH:mm')
}
$agenti = @()
Get-ChildItem $stato -Filter '*-agent.json' -ErrorAction SilentlyContinue | ForEach-Object {
  try { $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
  $nome = ($j.agent -replace '-agent$', '')
  $nome = (Get-Culture).TextInfo.ToTitleCase($nome)
  $inizio = if ($j.started) { [datetime]$j.started } else { $null }
  $fine = if ($j.ended) { [datetime]$j.ended } else { $null }
  $durata = if ($inizio -and $fine) { $s = [int]($fine - $inizio).TotalSeconds; if ($s -ge 120) { "$([int]($s/60)) min" } else { "${s}s" } } else { '-' }
  $appeso = ($j.state -eq 'running' -and $inizio -and ((Get-Date) - $inizio).TotalHours -gt 6)
  $ok = ($j.state -eq 'success')
  $agenti += [ordered]@{
    id = $j.agent; nome = "Agente $nome"; tipo = $(if ($appeso) { 'da controllare: stato fermo' } elseif ($j.state -eq 'running') { 'in corso' } elseif ($j.state -eq 'partial') { 'parziale' } else { 'Pianificato' })
    ultimaEsecuzione = Formatta-Quando $(if ($fine) { $j.ended } else { $j.started }); durata = $durata
    esito = $(if ($ok) { 'successo' } else { 'fallito' }); esitoSimbolo = $(if ($ok) { '✅' } elseif ($j.state -eq 'partial') { '⚠️' } else { '❌' }); costo = '0 €'
  }
  if ($appeso) { $servizi += [ordered]@{ id = $j.agent; nome = "Agente $nome"; stato = 'warning'; ultimoControllo = "alle $ora"; dettaglio = "Risulta 'in corso' dal $(Formatta-Quando $j.started): stato non aggiornato" } }
}

# --- lavori: richieste di Hermes (Esiti) + deleghe a Codex/Antigravity (events.jsonl). Mai il testo dei compiti.
$lavori = @()
$inCorsoF = Join-Path $stato 'richiesta-in-corso.json'
if (Test-Path $inCorsoF) {
  try { $ic = Get-Content $inCorsoF -Raw -Encoding UTF8 | ConvertFrom-Json
        if (((Get-Date) - [datetime]$ic.inizio).TotalHours -gt 2) { Remove-Item $inCorsoF -ErrorAction SilentlyContinue; throw 'orfano' }   # processo morto: non mostrare "in corso" per sempre
        $lavori += [ordered]@{ tipo = 'richiesta di Hermes'; nome = $ic.azione; stato = 'in corso'; quando = Formatta-Quando $ic.inizio } } catch {}
}
$esitiDir = Join-Path $jarvis 'DBVault\Machine\Richieste\Esiti'
Get-ChildItem $esitiDir -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 8 | ForEach-Object {
  $t = Get-Content $_.FullName -Encoding UTF8 -TotalCount 10
  $az = ($t | Where-Object { $_ -match '^azione:' } | Select-Object -First 1) -replace '^azione:\s*"?|"?\s*$', ''
  $st = ($t | Where-Object { $_ -match '^stato:' } | Select-Object -First 1) -replace '^stato:\s*', ''
  $lavori += [ordered]@{ tipo = 'richiesta di Hermes'; nome = $(if ($az) { $az } else { '(non valida)' }); stato = $st; quando = Formatta-Quando $_.LastWriteTime.ToString('s') }
}
$ev = Join-Path $jarvis 'DBVault\Machine\Logs\events.jsonl'
if (Test-Path $ev) {
  Get-Content $ev -Tail 300 -Encoding UTF8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
    Where-Object { $_.evento -eq 'delega' -and $_.esito -ne 'prova' } | Select-Object -Last 8 | ForEach-Object {
    $cart = ($_.cartella -split '[\\/]' | Where-Object { $_ } | Select-Object -Last 2) -join '/'; $lavori += [ordered]@{ tipo = 'delega'; nome = "$($_.a) in $cart"; stato = $_.esito; quando = Formatta-Quando $_.ts }
  }
}
$dati = [ordered]@{ generatoIl = (Get-Date).ToString('s'); reale = $true; servizi = $servizi; oggi = [ordered]@{ appuntamenti = @(); notizie = @() }; agenti = $agenti; lavori = $lavori; tempiRispostaHermes = @(); decisioni = @() }
$json = $dati | ConvertTo-Json -Depth 6
$u = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText("$uscita\dati-reali.js", "window.DATI_REALI = $json;`n", $u)
foreach ($f in 'dashboard.html', 'dashboard.css', 'dashboard.js', 'manifest.webmanifest') { if (Test-Path "$sorgente\$f") { Copy-Item "$sorgente\$f" "$uscita\$f" -Force } }
Write-Host "Dashboard aggiornata: $uscita\dashboard.html  ($($servizi.Count) servizi, $($agenti.Count) agenti)"
if ($Apri) { Start-Process "$uscita\dashboard.html" }
