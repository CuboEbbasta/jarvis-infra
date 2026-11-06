# Crea app\.env con password DB e segreto token casuali e l'hash scrypt del PIN.
# Non stampa mai valori. Il PIN viene hashato in un container Python usa-e-getta (via stdin).
# Uso:  powershell -File infra\crea-env-app.ps1 [-Force]
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$envFile = Join-Path $PSScriptRoot '..\app\.env'
if ((Test-Path $envFile) -and -not $Force) {
    Write-Host "app\.env esiste gia'. Usa -Force per rigenerarlo (invalida token e DB esistente)."
    exit 1
}
function New-Hex([int]$bytes) {
    $b = New-Object byte[] $bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    -join ($b | ForEach-Object { $_.ToString('x2') })
}
function To-Plain($s) {
    [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}
$pin1 = Read-Host 'Scegli il PIN (min 6 cifre)' -AsSecureString
$pin2 = Read-Host 'Ripeti il PIN' -AsSecureString
$p1 = To-Plain $pin1
$p2 = To-Plain $pin2
if ($p1 -ne $p2 -or $p1.Length -lt 6) { Write-Host 'PIN non valido o diverso.'; exit 1 }

$py = 'import sys,os,hashlib; pin=sys.stdin.readline().rstrip("\r\n").encode(); s=os.urandom(16); print("scrypt$%s$%s" % (s.hex(), hashlib.scrypt(pin,salt=s,n=2**14,r=8,p=1,dklen=32).hex()))'
$hash = ($p1 | docker run --rm -i python:3.12-slim python -c $py).Trim()
$p1 = $null; $p2 = $null
if (-not $hash.StartsWith('scrypt$')) { Write-Host 'Calcolo dell hash fallito.'; exit 1 }

# Apici singoli: l'hash contiene "$" che Compose altrimenti interpreta.
$lines = @(
    "JARVIS_DB_PASSWORD=$(New-Hex 24)",
    "JARVIS_TOKEN_SECRET=$(New-Hex 32)",
    "JARVIS_PIN_HASH='$hash'"
)
Set-Content -Path $envFile -Value $lines -Encoding ascii
Write-Host "Creato $envFile (valori non mostrati)."
