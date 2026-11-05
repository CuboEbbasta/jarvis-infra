# Jarvis - PROVA DI RIPRISTINO dei backup su GitHub: scarica (clone superficiale) i repo di backup in una cartella temporanea,
# controlla che siano leggibili e che NON contengano segreti o dati privati, poi cancella tutto.
# Non scrive nulla nei repo e non tocca i tuoi file. Uso: powershell -ExecutionPolicy Bypass -File .\test-ripristino.ps1
$ErrorActionPreference = 'Continue'
$jarvis = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $env:TEMP "jarvis-ripristino-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory $tmp | Out-Null
$esiti = @(); $ko = 0
$repo = @(
  @{ nome = 'jarvis-agents'; locale = "$jarvis\agents"; vietati = '(^|/)\.env($|\.)|\.key$|\.pem$|ical\.txt$|client_secret' },
  @{ nome = 'jarvis-infra'; locale = "$jarvis\infra"; vietati = '(^|/)\.env($|\.)|\.key$|\.pem$|callmebot\.txt$' },
  @{ nome = 'jarvis-vault'; locale = "$jarvis\DBVault"; vietati = '^Human/(?!AGENTS\.md$)|Machine/Contesto/(Email|Calendario|Interessi)|Machine/Agent-Outputs/posta/|(^|/)\.env($|\.)' }
)
foreach ($r in $repo) {
  $url = git -C $r.locale remote get-url origin 2>$null
  if (-not $url) { $esiti += "| ❌ | $($r.nome) | nessun remoto configurato |"; $ko++; continue }
  $d = Join-Path $tmp $r.nome
  git clone -q --depth 1 $url $d 2>$null
  if (-not (Test-Path $d)) { $esiti += "| ❌ | $($r.nome) | clone fallito |"; $ko++; continue }
  $file = @(git -C $d ls-files)
  $vietati = @($file | Where-Object { $_ -match $r.vietati -and $_ -notmatch 'example|esempio' })
  $locali = @(git -C $r.locale ls-files).Count
  $ok = ($file.Count -gt 0 -and $vietati.Count -eq 0)
  if (-not $ok) { $ko++ }
  $esiti += "| $(if ($ok) { '✅' } else { '❌' }) | $($r.nome) | $($file.Count) file nel backup (locali tracciati: $locali); file vietati: $($vietati.Count) |"
}
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
$ora = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$md = @('---', 'type: status', 'agent: test-ripristino', "updated: $ora", "problemi: $ko", '---', '# Prova di ripristino dei backup', '',
        "Eseguita il ${ora}: clone superficiale dei repo di backup, controllo contenuti, cartella temporanea cancellata.", '', '| | Repo | Esito |', '|---|---|---|') + $esiti +
      @('', 'Nota: prova la LETTURA del backup, non il ripristino completo su un PC vuoto (cronologia, Human/ locale e file .env non sono su GitHub per scelta).')
Set-Content (Join-Path $jarvis 'DBVault\Machine\Status\ripristino.md') $md -Encoding UTF8
$esiti | ForEach-Object { Write-Host $_ }
Write-Host "Prova di ripristino: $ko problemi"
