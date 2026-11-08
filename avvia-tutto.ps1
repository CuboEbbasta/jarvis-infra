# Jarvis - avvio orchestrato: porta su tutto cio' che serve e poi apre Jarvis Control Center.
# Uso:  powershell -ExecutionPolicy Bypass -File infra\avvia-tutto.ps1 [-Controlla] [-SenzaApp] [-Silenzioso] [-AutoTest]
#   -Controlla   solo verifica: non avvia nulla (ne' servizi ne' app)
#   -SenzaApp    avvia i servizi ma non apre la finestra di Jarvis Control Center
#   -Silenzioso  nessun output a console (usato dall'attivita' pianificata)
#   -AutoTest    prova pura della validazione della config con voci malevole d'esempio: non avvia e non controlla nulla
# Elenco e opzioni delle voci: infra\avvio-jarvis.json (nessun segreto). Ogni voce: se gia' OK la salta, altrimenti la avvia
# e aspetta (con timeout). Tetto globale (tetto_secondi, default 420 s) calcolato da UN solo istante iniziale.
# Codice di uscita 1 solo se, alla fine (dopo un secondo controllo a +30 s), una voce OBBLIGATORIA e' ancora ferma.
# Scrive il riepilogo (solo nomi e stati) in DBVault\Machine\Status\avvio.md. Non richiede amministratore, non legge .env.
# SICUREZZA: la config NON e' codice. Schema fisso (versione 1, tipi elencati, proprieta' note), vietati & | < > ^ % " e a-capo,
# nessun '..', eseguibili solo file esistenti sotto Program Files / LocalAppData / profilo / repo, script solo .ps1 in infra\,
# compose solo dentro il repo, CLI solo con argomento --version o models, niente cmd /c con stringhe concatenate.
param([switch]$Controlla, [switch]$SenzaApp, [switch]$Silenzioso, [switch]$AutoTest)
# Continue: i comandi nativi scrivono su stderr; gli esiti si leggono da ExitCode.
$ErrorActionPreference = 'Continue'
$jarvis = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cfgFile = Join-Path $PSScriptRoot 'avvio-jarvis.json'
$t0 = Get-Date
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Say([string]$m) { if (-not $Silenzioso) { Write-Host $m } }

# ================= validazione (pura) =================
$TIPI = @('docker', 'tailscale', 'http', 'compose', 'script', 'task', 'cli', 'processo')
$PROP_VOCE = @('nome', 'tipo', 'obbligatorio', 'abilitato', 'controllo', 'avvio', 'attesa_secondi', 'note')
$PROP_TOP = @('versione', 'tetto_secondi', 'nota', 'items')
$CLI_ARG = @('--version', 'models')
$VIETATI = [regex]'[&|<>^%"`\r\n\x00;]'
$RX_URL = [regex]'^http://(127\.0\.0\.1|localhost):\d{2,5}(/[A-Za-z0-9/_.-]*)?$'
$RX_NOME = [regex]'^[A-Za-z0-9_.-]+$'

function Radici { return @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:USERPROFILE, $jarvis) | Where-Object { $_ } }
function Espandi([string]$s) {
    $x = $s.Replace('{Jarvis}', $jarvis).Replace('{ProgramFiles}', $env:ProgramFiles).Replace('{LocalAppData}', $env:LOCALAPPDATA).Replace('{UserProfile}', $env:USERPROFILE)
    if ($x -match '[{}]') { return $null }                              # segnaposto sconosciuto
    if ($x -notmatch '^shell:' -and -not [IO.Path]::IsPathRooted($x)) { $x = Join-Path $jarvis $x }
    return $x
}
function Sotto([string]$path, [string[]]$radici) {
    try { $p = [IO.Path]::GetFullPath($path).TrimEnd('\') } catch { return $false }
    foreach ($r in $radici) { $rr = [IO.Path]::GetFullPath($r).TrimEnd('\'); if ($p.StartsWith($rr + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
function Err-Campo([string]$s) {
    if ($s -isnot [string] -or -not $s.Trim()) { return 'campo vuoto o non testuale' }
    if ($VIETATI.IsMatch($s)) { return 'caratteri vietati (& | < > ^ % " ; o a-capo)' }
    if ($s -match '(^|[\\/])\.\.([\\/]|$)') { return "percorso con '..' vietato" }
    return $null
}
function Err-Exe([string]$s) {          # percorso di eseguibile: .exe/.cmd sotto le radici consentite
    $e = Err-Campo $s; if ($e) { return $e }
    $x = Espandi $s; if (-not $x) { return 'segnaposto sconosciuto' }
    if ($x -notmatch '\.(exe|cmd)$') { return 'solo .exe/.cmd' }
    if (-not (Sotto $x (Radici))) { return 'eseguibile fuori dalle cartelle consentite' }
    return $null
}
function Err-Voce($it) {
    if ($it -isnot [psobject]) { return 'voce non valida' }
    foreach ($n in $it.PSObject.Properties.Name) { if ($PROP_VOCE -notcontains $n) { return "proprieta' sconosciuta: $n" } }
    if ($TIPI -notcontains $it.tipo) { return "tipo non ammesso: $($it.tipo)" }
    if ($it.nome -isnot [string] -or -not $it.nome.Trim() -or $it.nome.Length -gt 60 -or $it.nome -match '[\x00-\x1F|]') { return 'nome non valido' }
    foreach ($b in 'obbligatorio', 'abilitato') { if ($null -ne $it.$b -and $it.$b -isnot [bool]) { return "$b deve essere true/false" } }
    if ($null -ne $it.attesa_secondi) { $a = 0; if (-not [int]::TryParse("$($it.attesa_secondi)", [ref]$a) -or $a -lt 1 -or $a -gt 600) { return 'attesa_secondi fuori da 1-600' } }
    $c = [string]$it.controllo; $v = [string]$it.avvio
    switch ($it.tipo) {
        'docker' { if ($c -cne 'docker info') { return "controllo fisso: 'docker info'" }; return (Err-Exe $v) }
        'tailscale' { if ($c -cne 'tailscale status') { return "controllo fisso: 'tailscale status'" }; return (Err-Exe $v) }
        'http' { $e = Err-Campo $c; if ($e) { return $e }; if (-not $RX_URL.IsMatch($c)) { return 'solo URL http://127.0.0.1 o localhost' }; return (Err-Exe $v) }
        'script' {
            $e = Err-Campo $c; if ($e) { return $e }; if (-not $RX_URL.IsMatch($c)) { return 'solo URL http://127.0.0.1 o localhost' }
            $e = Err-Campo $v; if ($e) { return $e }; $x = Espandi $v
            if (-not $x -or $x -notmatch '\.ps1$' -or -not (Sotto $x @((Join-Path $jarvis 'infra')))) { return 'lo script deve essere un .ps1 dentro infra\' }
            return $null
        }
        'compose' {
            $e = Err-Campo $c; if ($e) { return $e }; if ($c -notmatch '^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$') { return 'elenco contenitori non valido' }
            $e = Err-Campo $v; if ($e) { return $e }
            $p = $v -split '#', 2; $x = Espandi $p[0]
            if (-not $x -or $x -notmatch 'docker-compose\.ya?ml$' -or -not (Sotto $x @($jarvis))) { return 'il file compose deve essere docker-compose.yml dentro il repo' }
            if ($p.Count -gt 1 -and $p[1].Trim() -and $p[1].Trim() -notmatch '^[A-Za-z0-9_.-]+( [A-Za-z0-9_.-]+)*$') { return 'servizi compose non validi' }
            return $null
        }
        'task' {
            if ((Err-Campo $c) -or $c -notmatch '^[A-Za-z0-9_. -]+$') { return 'controllo non valido' }
            if ((Err-Campo $v) -or $v -notmatch '^[A-Za-z0-9_ -]+$') { return 'nome attivita'' non valido' }
            return $null
        }
        'processo' {
            if ((Err-Campo $c) -or $c -notmatch '^[A-Za-z0-9_.-]+$') { return 'nome processo non valido' }
            if ($v -match '^shell:AppsFolder\\[A-Za-z0-9_.-]+![A-Za-z0-9_.-]+$') { return $null }
            return (Err-Exe $v)
        }
        'cli' {
            $e = Err-Campo $c; if ($e) { return $e }
            $i = $c.LastIndexOf(' '); if ($i -lt 1) { return "serve '<eseguibile> <argomento>'" }
            $arg = $c.Substring($i + 1); $exe = $c.Substring(0, $i)
            if ($CLI_ARG -cnotcontains $arg) { return "argomento non ammesso (solo: $($CLI_ARG -join ', '))" }
            if ($exe -match '^[A-Za-z0-9_-]+$') { return $null }       # nome nudo, cercato SOLO nel PATH
            return (Err-Exe $exe)
        }
    }
    return 'tipo non gestito'
}
function Err-Config($cfg) {
    foreach ($n in $cfg.PSObject.Properties.Name) { if ($PROP_TOP -notcontains $n) { return "proprieta' sconosciuta: $n" } }
    if ($cfg.versione -ne 1) { return "versione non supportata: $($cfg.versione) (attesa 1)" }
    if ($null -ne $cfg.tetto_secondi) { $t = 0; if (-not [int]::TryParse("$($cfg.tetto_secondi)", [ref]$t) -or $t -lt 60 -or $t -gt 900) { return 'tetto_secondi fuori da 60-900' } }
    if ($null -eq $cfg.items -or @($cfg.items).Count -eq 0) { return 'nessuna voce' }
    return $null
}

# ================= -AutoTest (puro) =================
if ($AutoTest) {
    $m = @(
        @{ d = 'cli con & (iniezione)'; j = '{"nome":"x","tipo":"cli","controllo":"codex --version & calc"}' },
        @{ d = 'cli con argomento libero'; j = '{"nome":"x","tipo":"cli","controllo":"codex --help"}' },
        @{ d = 'cli con percorso ..\'; j = '{"nome":"x","tipo":"cli","controllo":"..\\evil.exe --version"}' },
        @{ d = 'cli con |'; j = '{"nome":"x","tipo":"cli","controllo":"codex --version | calc"}' },
        @{ d = 'tipo sconosciuto'; j = '{"nome":"x","tipo":"shell","controllo":"calc"}' },
        @{ d = 'tipo app (non implementato)'; j = '{"nome":"x","tipo":"app","controllo":"x","avvio":"x"}' },
        @{ d = 'proprieta'' sconosciuta'; j = '{"nome":"x","tipo":"cli","controllo":"codex --version","extra":"1"}' },
        @{ d = 'variabile % nel percorso'; j = '{"nome":"x","tipo":"docker","controllo":"docker info","avvio":"%ComSpec%"}' },
        @{ d = 'exe fuori radici'; j = '{"nome":"x","tipo":"docker","controllo":"docker info","avvio":"C:\\Windows\\System32\\calc.exe"}' },
        @{ d = 'script fuori da infra'; j = '{"nome":"x","tipo":"script","controllo":"http://127.0.0.1:3030/","avvio":"app\\x.ps1"}' },
        @{ d = 'script con ..'; j = '{"nome":"x","tipo":"script","controllo":"http://127.0.0.1:3030/","avvio":"infra\\..\\app\\x.ps1"}' },
        @{ d = 'compose fuori dal repo'; j = '{"nome":"x","tipo":"compose","controllo":"a","avvio":"C:\\Temp\\docker-compose.yml#"}' },
        @{ d = 'compose servizi con ;'; j = '{"nome":"x","tipo":"compose","controllo":"a","avvio":"infra\\docker-compose.yml#a; calc"}' },
        @{ d = 'http verso host esterno'; j = '{"nome":"x","tipo":"http","controllo":"http://evil.example.com/","avvio":"{ProgramFiles}\\a.exe"}' },
        @{ d = 'a-capo nel campo'; j = '{"nome":"x","tipo":"cli","controllo":"codex\n--version"}' },
        @{ d = 'attivita'' con nome strano'; j = '{"nome":"x","tipo":"task","controllo":"a","avvio":"A&B"}' }
    )
    $ko = 0
    foreach ($s in $m) {
        $it = $s.j | ConvertFrom-Json; $e = Err-Voce $it
        if ($e) { Write-Host ("RIFIUTATA  {0,-34} -> {1}" -f $s.d, $e) } else { Write-Host ("ACCETTATA!  {0}" -f $s.d); $ko++ }
    }
    $e = Err-Config ('{"versione":2,"items":[{"nome":"x"}]}' | ConvertFrom-Json)
    if ($e) { Write-Host ("RIFIUTATA  {0,-34} -> {1}" -f 'versione 2', $e) } else { Write-Host 'ACCETTATA!  versione 2'; $ko++ }
    $e = Err-Config ('{"versione":1,"items":[{"nome":"x"}],"hack":1}' | ConvertFrom-Json)
    if ($e) { Write-Host ("RIFIUTATA  {0,-34} -> {1}" -f 'proprieta'' top sconosciuta', $e) } else { Write-Host 'ACCETTATA!  top'; $ko++ }
    if (Test-Path $cfgFile) {
        $real = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json; $bad = 0
        foreach ($it in $real.items) { $e = Err-Voce $it; if ($e) { Write-Host "CONFIG REALE, voce non valida: $($it.nome): $e"; $bad++ } }
        Write-Host ("Config reale: {0} voci, {1} non valide" -f @($real.items).Count, $bad)
        $ko += $bad
    }
    Write-Host $(if ($ko -eq 0) { 'AutoTest superato: tutte le voci malevole rifiutate.' } else { "AutoTest FALLITO ($ko)" })
    if ($ko -eq 0) { exit 0 } else { exit 3 }
}

# ================= esecuzione =================
function Residuo { return [int]($cap - ((Get-Date) - $t0).TotalSeconds) }

# Eseguibile: percorso assoluto (sotto le radici) oppure nome nudo cercato SOLO nel PATH. Mai cartella corrente/repo per prima.
function Risolvi-Exe([string]$spec) {
    if ($spec -match '^[A-Za-z0-9_-]+$') {
        foreach ($d in ($env:PATH -split ';')) {
            if (-not $d -or -not [IO.Path]::IsPathRooted($d) -or -not (Test-Path $d -PathType Container)) { continue }
            if (-not (Sotto (Join-Path $d 'x') (Radici))) { continue }
            foreach ($ext in '.exe', '.cmd') { $f = Join-Path $d ($spec + $ext); if (Test-Path $f -PathType Leaf) { return $f } }
        }
        return $null
    }
    $x = Espandi $spec
    if (-not $x -or $x -notmatch '\.(exe|cmd)$' -or -not (Sotto $x (Radici)) -or -not (Test-Path $x -PathType Leaf)) { return $null }
    return $x
}
# Esegue un file con argomenti (array) senza shell e con timeout; ritorna @{ code; out; timeout }.
function Esegui-Exe([string]$exe, [string[]]$argv = @(), [int]$timeout = 20, [string]$cwd = $jarvis) {
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    try {
        $sp = @{ FilePath = $exe; WorkingDirectory = $cwd; WindowStyle = 'Hidden'; PassThru = $true; RedirectStandardOutput = $o; RedirectStandardError = $e }
        if ($argv.Count -gt 0) { $sp.ArgumentList = $argv }
        $p = Start-Process @sp
        $null = $p.Handle                                   # senza questo ExitCode puo' risultare $null
        if (-not $p.WaitForExit($timeout * 1000)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            return @{ code = -1; out = 'timeout'; timeout = $true }
        }
        $t = ''; try { $t = (Get-Content $o -Raw -ErrorAction Stop) + (Get-Content $e -Raw -ErrorAction Stop) } catch { }
        return @{ code = [int]$p.ExitCode; out = "$t".Trim(); timeout = $false }
    } catch { return @{ code = -2; out = 'errore di esecuzione'; timeout = $false } }
    finally { Remove-Item $o, $e -Force -ErrorAction SilentlyContinue }
}
function Primo-Rigo([string]$s, [int]$max = 60) {
    $r = ($s -split "[\r\n]+" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $r) { return '' }
    $r = ($r -replace '[^\x20-\x7E]', '').Trim(); if ($r.Length -gt $max) { $r = $r.Substring(0, $max) }
    return $r
}
function Http-Ok([string]$url) {
    if (-not $RX_URL.IsMatch($url)) { return $false }
    try { return ((Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200) } catch { return $false }
}
function Docker-Exe { if (-not $script:dockerExe) { $script:dockerExe = Risolvi-Exe 'docker' }; return $script:dockerExe }

# --- controllo di una voce: @{ ok; det; warn } ---
function Controlla-Voce($it) {
    switch ($it.tipo) {
        'docker' {
            $d = Docker-Exe; if (-not $d) { return @{ ok = $false; det = 'docker.exe non trovato' } }
            $r = Esegui-Exe $d @('info') 20
            return @{ ok = ($r.code -eq 0); det = $(if ($r.code -eq 0) { 'motore attivo' } else { 'motore non raggiungibile' }) }
        }
        'tailscale' {
            $ts = Risolvi-Exe 'tailscale'; if (-not $ts) { $ts = Risolvi-Exe '{ProgramFiles}\Tailscale\tailscale.exe' }
            if (-not $ts) { return @{ ok = $false; det = 'Tailscale non installato' } }
            $r = Esegui-Exe $ts @('status') 15
            $ok = ($r.code -eq 0 -and $r.out -notmatch 'stopped|logged out|NeedsLogin|needs login|Starting')
            return @{ ok = $ok; det = $(if ($ok) { 'connesso' } elseif ($r.out -match 'logged out|NeedsLogin|needs login') { 'serve il login' } else { 'non connesso' }) }
        }
        { $_ -in 'http', 'script' } { $ok = Http-Ok $it.controllo; return @{ ok = $ok; det = $(if ($ok) { 'risponde' } else { 'non risponde' }) } }
        'compose' {
            $d = Docker-Exe; if (-not $d) { return @{ ok = $false; det = 'docker.exe non trovato' } }
            $r = Esegui-Exe $d @('ps', '--format', '{{.Names}}') 20
            if ($r.code -ne 0) { return @{ ok = $false; det = 'Docker non attivo' } }
            $su = @($r.out -split "[\r\n]+" | ForEach-Object { $_.Trim() })
            $man = @($it.controllo -split ',' | Where-Object { $_ } | Where-Object { $su -notcontains $_ })
            return @{ ok = ($man.Count -eq 0); det = $(if ($man.Count -eq 0) { 'contenitori attivi' } else { 'fermi: ' + ($man -join ', ') }) }
        }
        'task' {
            # il processo reale (python ... hermes_cli.main gateway), NON il .vbs/wscript che lo lancia; oppure l'attivita' in esecuzione
            $n = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $PID -and $_.Name -match '^(python|pythonw|node)\.exe$' -and $_.CommandLine -and $_.CommandLine.IndexOf($it.controllo, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count
            $t = Get-ScheduledTask -TaskName $it.avvio -ErrorAction SilentlyContinue
            $run = ($t -and $t.State -eq 'Running')
            return @{ ok = ($n -gt 0 -or $run); det = $(if ($n -gt 0) { 'processo attivo' } elseif ($run) { 'attivita'' in esecuzione' } else { 'processo assente' }) }
        }
        'processo' { $ok = [bool](Get-Process -Name $it.controllo -ErrorAction SilentlyContinue); return @{ ok = $ok; det = $(if ($ok) { 'in esecuzione' } else { 'non in esecuzione' }) } }
        'cli' {
            $i = $it.controllo.LastIndexOf(' '); $spec = $it.controllo.Substring(0, $i); $arg = $it.controllo.Substring($i + 1)
            $exe = Risolvi-Exe $spec
            if (-not $exe) { return @{ ok = $false; det = 'eseguibile non trovato' } }
            $r = Esegui-Exe $exe @($arg) ([int]$it.attesa_secondi)
            if ($r.timeout) { return @{ ok = $false; det = 'nessuna risposta (timeout)' } }
            if ($r.code -ne 0) { return @{ ok = $false; det = 'errore ' + $r.code + ' (' + (Primo-Rigo $r.out 40) + ')' } }
            # esiste e risponde; un eventuale testo di login nell'output e' solo un indizio, non una verifica dell'accesso
            if ($r.out -match 'log ?in|not logged|sign in|unauthori[sz]ed') { return @{ ok = $true; warn = $true; det = 'esiste; l''output cita il login (da verificare a mano)' } }
            return @{ ok = $true; det = 'esiste e risponde (' + (Primo-Rigo $r.out 30) + '); il login non e'' verificato; parte su richiesta' }
        }
    }
    return @{ ok = $false; det = 'tipo sconosciuto' }
}

# informazioni sull'override Tailscale dell'app (dai binding del contenitore, anche se fermo)
function Ip-Tailscale-App {
    $d = Docker-Exe; if (-not $d) { return $null }
    $r = Esegui-Exe $d @('inspect', '--format', '{{json .HostConfig.PortBindings}}', 'app-api-1') 15
    if ($r.code -eq 0 -and $r.out -match '"HostIp":"(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3})"') { return $Matches[1] }
    return $null
}

# --- avvio di una voce (solo se non -Controlla). Ritorna $true se il comando e' partito ---
function Avvia-Voce($it) {
    switch ($it.tipo) {
        'docker' {
            if (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue) { return $true }   # gia' in avvio (Run di Windows): solo attesa
            $e = Risolvi-Exe $it.avvio; if (-not $e) { return $false }
            Start-Process -FilePath $e -WindowStyle Minimized; return $true
        }
        'tailscale' {
            if (Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue) { return $false }   # gia' aperto: serve il login a mano
            $e = Risolvi-Exe $it.avvio; if (-not $e) { return $false }
            Start-Process -FilePath $e; return $true
        }
        'http' {
            $e = Risolvi-Exe $it.avvio; if (-not $e) { return $false }
            $nomi = @([IO.Path]::GetFileNameWithoutExtension($e)); if ($nomi[0] -match '^ollama') { $nomi += 'ollama' }
            foreach ($n in $nomi) { if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true } }   # gia' aperto: solo attesa, niente seconda finestra
            Start-Process -FilePath $e; return $true
        }
        'processo' {
            if ($it.avvio -match '^shell:') { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList $it.avvio; return $true }
            $e = Risolvi-Exe $it.avvio; if (-not $e) { return $false }; Start-Process -FilePath $e; return $true
        }
        'compose' {
            $d = Docker-Exe; if (-not $d) { return $false }
            $parti = $it.avvio -split '#', 2
            $f = Espandi $parti[0]; if (-not (Test-Path $f -PathType Leaf)) { return $false }
            $a = @('compose', '-f', ('"' + $f + '"'), 'up', '-d', '--no-build')
            if ($parti.Count -gt 1 -and $parti[1].Trim()) { $a += @($parti[1].Trim() -split ' ') }
            $r = Esegui-Exe $d $a ([Math]::Max(10, [Math]::Min([int]$it.attesa_secondi, (Residuo)))) (Split-Path $f -Parent)
            return ($r.code -eq 0)
        }
        'script' {
            $f = Espandi $it.avvio; if (-not (Test-Path $f -PathType Leaf)) { return $false }
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $f + '"'))
            if ((Split-Path $f -Leaf) -eq 'avvia-app.ps1') {          # all'accesso: mai npm ci; mantiene l'override Tailscale se in uso
                $a += '-SenzaCostruire'
                $ip = Ip-Tailscale-App; if ($ip) { $a += @('-Tailscale', '-TailscaleIp', $ip) }
            }
            $r = Esegui-Exe $psExe $a ([Math]::Max(10, [Math]::Min([int]$it.attesa_secondi, (Residuo))))
            return ($r.code -eq 0)
        }
        'task' {
            if (-not (Get-ScheduledTask -TaskName $it.avvio -ErrorAction SilentlyContinue)) { return $false }
            try { Start-ScheduledTask -TaskName $it.avvio -ErrorAction Stop; return $true } catch { return $false }
        }
    }
    return $false
}

# ================= config =================
if (-not (Test-Path $cfgFile)) { Say "Manca $cfgFile"; exit 2 }
try { $cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Say 'avvio-jarvis.json non valido (JSON)'; exit 2 }
$e = Err-Config $cfg; if ($e) { Say "avvio-jarvis.json rifiutato: $e"; exit 2 }
$cap = [int]$(if ($cfg.tetto_secondi) { $cfg.tetto_secondi } else { 420 })

$righe = New-Object System.Collections.ArrayList
$dockerOk = $false
function Riga($it, [string]$nome, [string]$stato, [string]$det, [bool]$obb) {
    [void]$righe.Add([pscustomobject]@{ Voce = $nome; Stato = $stato; Dettaglio = $det; Obb = $obb; It = $it })
    Say ('  {0,-40} {1,-12} {2}' -f $nome, $stato, $det)
}
function Falliti { return @($righe | Where-Object { $_.Obb -and $_.Stato -in @('NON OK', 'saltato', 'non attivo') } | ForEach-Object { $_.Voce }) }

# attende che la voce diventi OK entro i secondi (ricalcolati dal tetto globale a ogni chiamata)
function Attendi-Voce($it, [int]$secondi) {
    $fine = (Get-Date).AddSeconds([Math]::Min($secondi, (Residuo)))
    $c = Controlla-Voce $it
    while (-not $c.ok -and (Get-Date) -lt $fine) { Start-Sleep 3; $c = Controlla-Voce $it }
    return $c
}

Say ("Jarvis - avvio {0}" -f $(if ($Controlla) { '(solo controllo)' } else { '' }))
foreach ($it in $cfg.items) {
    $nome = [string]$it.nome; $obb = ($it.obbligatorio -eq $true)
    $e = Err-Voce $it
    if ($e) { Riga $it $(if ($nome) { $nome } else { '(voce senza nome)' }) 'NON OK' "voce rifiutata dalla config: $e" $obb; continue }
    if ($it.abilitato -eq $false) { Riga $it $nome 'disattivato' 'voce spenta in avvio-jarvis.json' $false; continue }
    $c = Controlla-Voce $it
    if ($c.ok) {
        if ($it.tipo -eq 'docker') { $dockerOk = $true }
        Riga $it $nome $(if ($c.warn) { 'attenzione' } else { 'OK' }) $c.det $obb; continue
    }
    if ($it.tipo -eq 'cli') { Riga $it $nome 'NON OK' $c.det $obb; continue }
    if ($Controlla) { Riga $it $nome 'non attivo' ($c.det + ' (non avviato: modo controllo)') $obb; continue }
    if ($it.tipo -in @('compose', 'script') -and -not $dockerOk) { Riga $it $nome 'saltato' 'in attesa di Docker, non pronto' $obb; continue }
    if ((Residuo) -le 5) { Riga $it $nome 'saltato' 'tetto di tempo raggiunto' $obb; continue }
    $partita = Avvia-Voce $it
    $c2 = $c
    if ($partita) { $c2 = Attendi-Voce $it ([int]$it.attesa_secondi) }
    if ($c2.ok) {
        if ($it.tipo -eq 'docker') { $dockerOk = $true }
        Riga $it $nome 'avviato' $c2.det $obb
    } else {
        $d = $(if (-not $partita) { 'avvio non possibile (' + $c.det + ')' } else { 'non pronto entro ' + [int]$it.attesa_secondi + ' s (' + $c2.det + ')' })
        Riga $it $nome 'NON OK' $d $obb
    }
}

# --- secondo controllo: i contenitori hanno restart: unless-stopped e Docker puo' essere arrivato tardi ---
if (-not $Controlla -and (Falliti).Count -gt 0) {
    Say '  ... una voce obbligatoria e'' ferma: nuovo controllo tra 30 s'
    Start-Sleep 30
    foreach ($r in @($righe | Where-Object { $_.Obb -and $_.Stato -in @('NON OK', 'saltato') })) {
        $it = $r.It; if ((Err-Voce $it)) { continue }
        $c = Controlla-Voce $it
        if (-not $c.ok -and $r.Stato -eq 'saltato' -and ($dockerOk -or ($righe | Where-Object { $_.It.tipo -eq 'docker' -and $_.Stato -in @('OK', 'avviato') }))) {
            $dockerOk = $true
            if (Avvia-Voce $it) { $c = Attendi-Voce $it 90 }
        }
        if ($c.ok) { $r.Stato = 'avviato'; $r.Dettaglio = 'pronto al secondo controllo (' + $c.det + ')'; if ($it.tipo -eq 'docker') { $dockerOk = $true } }
    }
}

# --- finestra di Jarvis Control Center ---
function Trova-App {
    $cand = New-Object System.Collections.ArrayList
    $reg = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } | Where-Object { $_.DisplayName -eq 'Jarvis' } | Select-Object -First 1
    if ($reg) {
        $dir = $reg.InstallLocation; if (-not $dir -and $reg.DisplayIcon) { $dir = Split-Path ($reg.DisplayIcon -replace '"', '') -Parent }
        if ($dir) { [void]$cand.Add(@{ dir = $dir; tipo = 'installata' }) }
    }
    [void]$cand.Add(@{ dir = "$env:LOCALAPPDATA\Jarvis"; tipo = 'installata' }); [void]$cand.Add(@{ dir = "$env:LOCALAPPDATA\Programs\Jarvis"; tipo = 'installata' })
    foreach ($c in $cand) {
        if (-not (Test-Path $c.dir -PathType Container) -or -not (Sotto (Join-Path $c.dir 'x') @($env:LOCALAPPDATA, $env:ProgramFiles))) { continue }
        $x = Get-ChildItem $c.dir -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'uninst' } | Select-Object -First 1
        if ($x) { return @{ exe = $x.FullName; tipo = $c.tipo } }
    }
    $b = Join-Path $jarvis 'app\desktop\src-tauri\target\release\jarvis-control-center.exe'
    if (Test-Path $b -PathType Leaf) { return @{ exe = $b; tipo = 'compilata (non installata)' } }
    return $null
}
$nomeApp = 'Jarvis Control Center (finestra)'
if ($SenzaApp) { Riga $null $nomeApp 'disattivato' 'opzione -SenzaApp' $false }
else {
    $app = Trova-App
    if (-not $app) { Riga $null $nomeApp 'NON OK' 'app non installata ne'' compilata: vedi README (Installazione)' $false }
    else {
        $nomeProc = [IO.Path]::GetFileNameWithoutExtension($app.exe)
        if (Get-Process -Name $nomeProc -ErrorAction SilentlyContinue) { Riga $null $nomeApp 'OK' ('gia'' aperta - ' + $app.tipo) $false }
        elseif ($Controlla) { Riga $null $nomeApp 'non attivo' ($app.tipo + ' - non aperta (modo controllo)') $false }
        elseif (-not (Http-Ok 'http://127.0.0.1:3030/api/health')) { Riga $null $nomeApp 'saltato' 'il backend (porta 3030) non risponde' $false }
        else { Start-Process -FilePath $app.exe; Riga $null $nomeApp 'avviato' $app.tipo $false }
    }
}

# --- riepilogo markdown (solo nomi e stati) ---
$obbFalliti = Falliti
$ko = @($righe | Where-Object { $_.Stato -eq 'NON OK' }).Count
$stato = $(if ($obbFalliti.Count -gt 0) { 'failed' } elseif ($ko -gt 0) { 'partial' } else { 'success' })
$ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
$durata = [int]((Get-Date) - $t0).TotalSeconds
$md = @('---', 'type: agent-status', 'agent: avvio', "state: $stato", 'task: "Avvio di Jarvis"', 'phase: "finito"',
        "progress: `"$ko da guardare`"", 'model: nessuno', "updated: $ts", "ended: $ts", "result: `"$stato`"", '---',
        ("# Avvio di Jarvis - " + (Get-Date -Format 'dd/MM HH:mm') + $(if ($Controlla) { ' (solo controllo)' } else { '' })), '',
        '| Voce | Stato | Dettaglio |', '|---|---|---|')
foreach ($r in $righe) { $md += ('| {0} | {1} | {2} |' -f $r.Voce, $r.Stato, ($r.Dettaglio -replace '\|', '/')) }
$md += @('', "Durata: $durata s. File generato da infra/avvia-tutto.ps1: non modificare. Config: infra/avvio-jarvis.json.")
try {
    $dir = Join-Path $jarvis 'DBVault\Machine\Status'
    New-Item -ItemType Directory -Force $dir | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'avvio.md'), ($md -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
} catch { Say 'Riepilogo non scritto in DBVault' }

Say ''
Say ("Esito: $stato (durata $durata s)")

# --- avviso Telegram solo se una voce obbligatoria e' ANCORA ferma alla fine (solo nomi) ---
if ($obbFalliti.Count -gt 0 -and -not $Controlla) {
    try {
        . (Join-Path $PSScriptRoot 'avvisa-telegram.ps1')
        [void](Invia-Avviso ('Jarvis: avvio non riuscito -> ' + ($obbFalliti -join ', ') + '. Dettagli: Machine/Status/avvio.md'))
    } catch { }
}
if ($obbFalliti.Count -gt 0) { exit 1 }
exit 0
