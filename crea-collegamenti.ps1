# Brina - crea i collegamenti "Brina" nel menu Start (e, a richiesta, sul Desktop) verso l'app installata.
# Di norma serve solo se l'installatore non li ha creati (l'NSIS crea gia' quello nel menu Start e offre il Desktop a fine installazione).
# Uso:  powershell -ExecutionPolicy Bypass -File infra\crea-collegamenti.ps1 [-Desktop] [-Prova]
#   -Desktop  crea anche il collegamento sul Desktop      -Prova  mostra cosa farebbe senza creare nulla
# Per la barra delle applicazioni: Windows non permette di farlo da script; apri Brina, clic destro sull'icona -> "Aggiungi alla barra".
param([switch]$Desktop, [switch]$Prova)
$ErrorActionPreference = 'Stop'
$exe = $null
$reg = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } | Where-Object { $_.DisplayName -in 'Brina', 'Jarvis' } | Select-Object -First 1
if ($reg -and $reg.InstallLocation) { $exe = Get-ChildItem $reg.InstallLocation -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'uninst' } | Select-Object -First 1 -ExpandProperty FullName }
# l'app installata puo' chiamarsi ancora «Jarvis» (installatore precedente) o «Brina» (dal 15/11)
if (-not $exe) { $exe = Get-ChildItem "$env:LOCALAPPDATA\Brina", "$env:LOCALAPPDATA\Programs\Brina", "$env:LOCALAPPDATA\Jarvis", "$env:LOCALAPPDATA\Programs\Jarvis" -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'uninst' } | Select-Object -First 1 -ExpandProperty FullName }
if (-not $exe) { Write-Host "Brina non risulta installato: esegui prima l'installatore (app\desktop\src-tauri\target\release\bundle\nsis\Brina_*_x64-setup.exe)."; exit 1 }
$dest = @(Join-Path ([Environment]::GetFolderPath('Programs')) 'Brina.lnk')
if ($Desktop) { $dest += Join-Path ([Environment]::GetFolderPath('Desktop')) 'Brina.lnk' }
foreach ($d in $dest) {
    if ($Prova) { Write-Host "Creerei: $d -> $exe (icona dell'exe)"; continue }
    $sh = New-Object -ComObject WScript.Shell
    $l = $sh.CreateShortcut($d); $l.TargetPath = $exe; $l.WorkingDirectory = Split-Path $exe; $l.IconLocation = "$exe,0"
    $l.Description = 'Brina Control Center'; $l.Save(); Write-Host "Creato: $d"
}
