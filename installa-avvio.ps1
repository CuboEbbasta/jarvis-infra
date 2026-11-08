# Jarvis - avvio automatico all'accesso a Windows (opt-in, per utente, senza amministratore).
# Uso:  powershell -ExecutionPolicy Bypass -File infra\installa-avvio.ps1 -Stato
#       ... -Prova [-ApriApp:$false]       mostra cosa verrebbe registrato, senza registrare nulla
#       ... -Installa [-ApriApp:$false]    registra l'attivita' "Jarvis Avvio" (30 s dopo l'accesso, esegue avvia-tutto.ps1 senza finestre)
#       ... -Rimuovi                       toglie l'attivita'
#       ... -Ripristina                    toglie la nuova e ri-registra l'attivita' precedente dal backup XML (rollback)
#   -SenzaFinestra  (equivale a -ApriApp:$false; con 'powershell -File' usa -SenzaFinestra)
#   -ApriApp:$false  all'accesso partono solo i servizi, la finestra di Jarvis NON si apre (default: si apre)
# Stesso schema delle altre attivita' Jarvis: wscript.exe //B lancia-nascosto.vbs <file .cmdline> (nessuna finestra, nemmeno il lampo).
# NOTA: esiste gia' un'attivita' "Jarvis Avvio" (avvio ridotto: avvia-jarvis.ps1 via lancia-nascosto.vbs, ritardo 1 min): -Installa la SOSTITUISCE.
#       Prima ne salva l'XML in infra\hidden\backup\jarvis-avvio-precedente.xml (verificato con [xml]; se non e' valido -Installa si ferma).
#       Rollback: -Ripristina, cioe': Register-ScheduledTask -Xml (Get-Content infra\hidden\backup\jarvis-avvio-precedente.xml -Raw) -TaskName 'Jarvis Avvio' -Force
#       ATTENZIONE: NON lanciare in futuro 'avvia-jarvis.ps1 -Schedule': ri-crea 'Jarvis Avvio' (visibile, 1 min) e sovrascrive in silenzio quella nuova.
# Percorsi fissi (nessun input dell'utente viene eseguito). Non apre porte, non richiede privilegi elevati.
param([switch]$Installa, [switch]$Rimuovi, [switch]$Ripristina, [switch]$Stato, [switch]$Prova, [bool]$ApriApp = $true, [switch]$SenzaFinestra)
$ErrorActionPreference = 'Stop'
$nomeTask = 'Jarvis Avvio'
$hidden = Join-Path $PSScriptRoot 'hidden'
$vbs = Join-Path $PSScriptRoot 'lancia-nascosto.vbs'
$script = Join-Path $PSScriptRoot 'avvia-tutto.ps1'
$cmdFile = Join-Path $hidden 'jarvis-avvio-tutto.cmdline'
$backup = Join-Path $hidden 'backup\jarvis-avvio-precedente.xml'

if ($SenzaFinestra) { $ApriApp = $false }
if (-not ($Installa -or $Rimuovi -or $Ripristina -or $Stato -or $Prova)) { $Stato = $true }

function Riga-Comando {
    $c = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script + '" -Silenzioso'
    if (-not $ApriApp) { $c += ' -SenzaApp' }
    return $c
}
function Nuova-Definizione {
    $utente = "$env:USERDOMAIN\$env:USERNAME"
    $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B //Nologo "' + $vbs + '" "' + $cmdFile + '"')
    $trg = New-ScheduledTaskTrigger -AtLogOn -User $utente
    $trg.Delay = 'PT30S'
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    $pri = New-ScheduledTaskPrincipal -UserId $utente -LogonType Interactive -RunLevel Limited
    return @{ Action = $act; Trigger = $trg; Settings = $set; Principal = $pri; Utente = $utente }
}
function Mostra-Definizione($d) {
    Write-Host "Attivita':        $nomeTask (utente $($d.Utente), livello normale, niente amministratore)"
    Write-Host "Quando:           all'accesso, dopo 30 secondi"
    Write-Host "Azione:           $($d.Action.Execute) $($d.Action.Arguments)"
    Write-Host "File comando:     $cmdFile"
    Write-Host "  contenuto:      $(Riga-Comando)"
    Write-Host "Impostazioni:     StartWhenAvailable, nessuno stop a batteria, limite 15 minuti, una sola istanza"
    Write-Host ("Finestra Jarvis:  " + $(if ($ApriApp) { 'si apre all''accesso' } else { 'NON si apre (solo servizi)' }))
}

if ($Stato) {
    $t = Get-ScheduledTask -TaskName $nomeTask -ErrorAction SilentlyContinue
    if (-not $t) { Write-Host "Avvio automatico: NON installato (nessuna attivita' '$nomeTask')."; }
    else {
        $a = $t.Actions | Select-Object -First 1
        $nostro = ($a.Arguments -match 'jarvis-avvio-tutto\.cmdline')
        $i = Get-ScheduledTaskInfo -TaskName $nomeTask
        Write-Host "Attivita' '$nomeTask': stato $($t.State)"
        Write-Host ("Tipo:        " + $(if ($nostro) { 'nuovo avvio completo (avvia-tutto.ps1)' } else { 'VECCHIO avvio ridotto (avvia-jarvis.ps1): -Installa lo sostituisce' }))
        if ($nostro -and (Test-Path $cmdFile)) { Write-Host ("Finestra:    " + $(if ((Get-Content $cmdFile -Raw) -match '-SenzaApp') { 'non si apre (solo servizi)' } else { 'si apre all''accesso' })) }
        Write-Host "Trigger:     $(($t.Triggers | Select-Object -First 1).CimClass.CimClassName) ritardo $(($t.Triggers | Select-Object -First 1).Delay)"
        Write-Host "Ultima esecuzione: $($i.LastRunTime) - esito $($i.LastTaskResult)"
    }
    Write-Host ("Riepilogo ultimo avvio: " + $(if (Test-Path (Join-Path $PSScriptRoot '..\DBVault\Machine\Status\avvio.md')) { 'DBVault\Machine\Status\avvio.md' } else { 'non ancora generato' }))
}

if ($Prova) {
    Write-Host '--- PROVA: non registro nulla ---'
    Mostra-Definizione (Nuova-Definizione)
    if (Get-ScheduledTask -TaskName $nomeTask -ErrorAction SilentlyContinue) { Write-Host "Esiste gia' un'attivita' '$nomeTask': verrebbe sostituita (XML precedente salvato in $backup)." }
}

if ($Installa) {
    foreach ($f in @($vbs, $script)) { if (-not (Test-Path $f)) { Write-Host "Manca $f"; exit 1 } }
    New-Item -ItemType Directory -Force (Split-Path $backup) | Out-Null
    $esiste = Get-ScheduledTask -TaskName $nomeTask -ErrorAction SilentlyContinue
    if ($esiste -and -not (($esiste.Actions | Select-Object -First 1).Arguments -match 'jarvis-avvio-tutto\.cmdline')) {
        $xmlPrec = (Export-ScheduledTask -TaskName $nomeTask | Out-String)
        try { $px = [xml]$xmlPrec; if (-not $px.Task.Actions) { throw 'senza azioni' } }
        catch { Write-Host "Backup dell'attivita' precedente non valido: mi fermo senza modificare nulla." -ForegroundColor Yellow; exit 1 }
        Set-Content $backup -Value $xmlPrec -Encoding Unicode
        Write-Host "Salvata l'attivita' precedente in $backup"
    }
    Set-Content $cmdFile -Value (Riga-Comando) -Encoding ASCII
    $d = Nuova-Definizione
    try {
        Register-ScheduledTask -TaskName $nomeTask -Action $d.Action -Trigger $d.Trigger -Settings $d.Settings -Principal $d.Principal -Force | Out-Null
    } catch { Write-Host "Registrazione non riuscita: $($_.Exception.Message.Split([char]10)[0])" -ForegroundColor Yellow; exit 1 }
    Mostra-Definizione $d
    Write-Host "Fatto. Prova subito:  Start-ScheduledTask -TaskName '$nomeTask'   (oppure riavvia Windows)."
}

if ($Rimuovi) {
    if (Get-ScheduledTask -TaskName $nomeTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $nomeTask -Confirm:$false
        Write-Host "Attivita' '$nomeTask' rimossa: all'accesso non parte piu' nulla di Jarvis da qui."
        Write-Host "Per rimettere il vecchio avvio ridotto:  powershell -ExecutionPolicy Bypass -File infra\installa-avvio.ps1 -Ripristina"
    } else { Write-Host "Nessuna attivita' '$nomeTask' da rimuovere." }
}

if ($Ripristina) {
    if (-not (Test-Path $backup)) { Write-Host "Nessun backup in ${backup}: niente da ripristinare."; exit 1 }
    $xmlTxt = Get-Content $backup -Raw
    try { $x = [xml]$xmlTxt; if (-not $x.Task.Actions) { throw 'senza azioni' } } catch { Write-Host "Il backup non e' un XML di attivita' valido: nessuna modifica." -ForegroundColor Yellow; exit 1 }
    try { Register-ScheduledTask -Xml $xmlTxt -TaskName $nomeTask -Force | Out-Null }
    catch { Write-Host "Ripristino non riuscito: $($_.Exception.Message.Split([char]10)[0])" -ForegroundColor Yellow; exit 1 }
    Write-Host "Ripristinata l'attivita' '$nomeTask' precedente (avvio ridotto). Non lanciare avvia-jarvis.ps1 -Schedule."
}