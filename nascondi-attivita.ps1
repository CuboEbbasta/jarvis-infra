# Jarvis - fa girare le attivita' pianificate Jarvis senza finestre (via lancia-nascosto.vbs).
# Causa del problema: powershell.exe -WindowStyle Hidden mostra comunque la finestra per un istante, e docker apre altre console.
# Cosa fa: per ogni attivita' 'Jarvis *' che lancia powershell.exe salva il comando in infra\hidden\<nome>.cmdline,
#          esporta il vecchio XML in infra\hidden\backup\ e sostituisce l'azione con wscript.exe //B lancia-nascosto.vbs <file>.
# Idempotente. Per annullare: Register-ScheduledTask -Xml (Get-Content <backup>.xml -Raw) -TaskName '<nome>' -Force
# Nota: rilanciare schedule-*.ps1 / esegui-richieste.ps1 -Schedule rimette l'azione visibile: poi rilancia questo script.
$ErrorActionPreference = 'Stop'
$hidden = Join-Path $PSScriptRoot 'hidden'; $backup = Join-Path $hidden 'backup'
New-Item -ItemType Directory -Force $backup | Out-Null
$vbs = Join-Path $PSScriptRoot 'lancia-nascosto.vbs'
foreach ($t in Get-ScheduledTask -TaskPath '\' | Where-Object TaskName -like 'Jarvis*') {
    $a = $t.Actions | Select-Object -First 1
    if ($a.Execute -notmatch 'powershell\.exe$') { Write-Host "= $($t.TaskName): gia' nascosta o non powershell ($($a.Execute))"; continue }
    $slug = ($t.TaskName -replace '[^\w]+', '-').ToLower()
    $file = Join-Path $hidden "$slug.cmdline"
    Export-ScheduledTask -TaskName $t.TaskName | Set-Content (Join-Path $backup "$slug.xml") -Encoding UTF8
    Set-Content $file -Value ("powershell.exe " + $a.Arguments) -Encoding ASCII
    $nuova = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "//B //Nologo `"$vbs`" `"$file`""
    try { Set-ScheduledTask -TaskName $t.TaskName -Action $nuova | Out-Null; Write-Host "+ $($t.TaskName): ora senza finestre" }
    catch { Write-Host "! $($t.TaskName): non modificata ($($_.Exception.Message.Split([char]10)[0])). Riprova da PowerShell come amministratore." -ForegroundColor Yellow }
}
