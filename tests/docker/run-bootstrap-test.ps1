[CmdletBinding()]
param(
    # URL raw dello script pubblicato: lo scarica e usa questo invece del file locale.
    [string]$ScriptUrl,
    # Salta l'installazione reale di PowerShell e dei moduli (la parte piu lenta).
    [switch]$SkipModules
)

$ErrorActionPreference = "Stop"

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$image = "ara-bootstrap-test"

docker build -q -f (Join-Path $PSScriptRoot "Dockerfile") -t $image $repositoryRoot
if ($LASTEXITCODE -ne 0) { throw "Build dell'immagine non riuscita." }

$runArgs = @("run", "--rm")
if ($ScriptUrl) { $runArgs += @("-e", "ARA_TEST_SCRIPT_URL=$ScriptUrl") }
if ($SkipModules) { $runArgs += @("-e", "ARA_TEST_SKIP_MODULES=1") }
$runArgs += $image

docker @runArgs
if ($LASTEXITCODE -ne 0) { throw "Test di bootstrap falliti." }
