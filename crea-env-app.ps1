# Crea app\.env con password DB e segreto token casuali e l'hash scrypt del PIN.
# Non stampa mai valori. Il PIN viene hashato in un container Python usa-e-getta (via stdin),
# senza rete, in sola lettura e con immagine fissata per digest.
# Uso:  powershell -File infra\crea-env-app.ps1 [-Force]
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$envFile = Join-Path $PSScriptRoot '..\app\.env'
if ((Test-Path $envFile) -and -not $Force) {
    Write-Host "app\.env esiste gia'. Usa -Force per rigenerarlo (invalida token e DB esistente)."
    exit 1
}
# Immagine fissata per digest (letto con: docker image inspect --format "{{index .RepoDigests 0}}" python:3.12-slim
# dopo "docker pull python:3.12-slim", il 2026-11-06). Per aggiornarla rifai quei due comandi.
$image = 'python:3.12-slim@sha256:4840d514c583a4d3d8cad3940e68dee6f0f6f3635c12fcd0a3d74c21a5b93a54'

function New-Hex([int]$bytes) {
    $b = New-Object byte[] $bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($b); $rng.Dispose()
    -join ($b | ForEach-Object { $_.ToString('x2') })
}
function To-Plain($s) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
$pin1 = Read-Host 'Scegli il PIN (solo cifre, 6-12)' -AsSecureString
$pin2 = Read-Host 'Ripeti il PIN' -AsSecureString
$p1 = To-Plain $pin1
$p2 = To-Plain $pin2
$pin1.Dispose(); $pin2.Dispose()
if ($p1 -cne $p2 -or $p1 -notmatch '^[0-9]{6,12}$') { Write-Host 'PIN non valido (solo cifre, 6-12) o diverso.'; exit 1 }

# Nessun doppio apice nel codice Python: PowerShell 5.1 li perde passando l'argomento a docker.
$py = 'import sys,os,hashlib; pin=sys.stdin.readline().rstrip(chr(13)+chr(10)).encode(); s=os.urandom(16); print(''scrypt$%s$%s'' % (s.hex(), hashlib.scrypt(pin,salt=s,n=2**14,r=8,p=1,dklen=32).hex()))'
$out = $p1 | docker run --rm -i --network none --read-only --cap-drop ALL --pids-limit 64 --memory 256m --security-opt no-new-privileges $image python -c $py
$p1 = $null; $p2 = $null
if ($LASTEXITCODE -ne 0 -or -not $out) { Write-Host 'Calcolo dell''hash fallito (Docker attivo?).'; exit 1 }
$hash = ($out | Out-String).Trim()
if (-not $hash.StartsWith('scrypt$')) { Write-Host 'Calcolo dell''hash fallito.'; exit 1 }

# Crea il file vuoto, limita i permessi all'utente corrente, POI scrive i segreti.
New-Item -ItemType File -Path $envFile -Force | Out-Null
$envFile = (Resolve-Path $envFile).Path
icacls $envFile /inheritance:r /grant:r "${env:USERNAME}:(F)" | Out-Null
if ($LASTEXITCODE -ne 0) { Remove-Item $envFile -Force; Write-Host 'Impossibile limitare i permessi di app\.env: file rimosso.'; exit 1 }

# Apici singoli: l'hash contiene "$" che Compose altrimenti interpreta.
$lines = @(
    "JARVIS_DB_PASSWORD=$(New-Hex 24)",
    "JARVIS_TOKEN_SECRET=$(New-Hex 32)",
    "JARVIS_PIN_HASH='$hash'"
)
Set-Content -Path $envFile -Value $lines -Encoding ascii
Write-Host "Creato $envFile (valori non mostrati). Permessi:"
icacls $envFile
